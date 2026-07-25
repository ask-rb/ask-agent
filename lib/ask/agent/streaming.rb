# frozen_string_literal: true

require "json"

module Ask
  module Agent
    # Framework-agnostic SSE streaming for agent sessions.
    #
    # Returns a Rack-compatible Enumerator that yields SSE-formatted strings
    # as the agent runs. Works with any Rack server (Puma, Falcon, etc.)
    # without requiring ActionController::Live or Rails.
    #
    # @example In a Rails controller (with ActionController::Live::SSE)
    #   def create
    #     response.headers["Content-Type"] = "text/event-stream"
    #     sse = SSE.new(response.stream)
    #
    #     Ask::Agent::Streaming.run(session, prompt) do |type, data|
    #       sse.write(data, event: type)
    #     end
    #   ensure
    #     sse&.close
    #   end
    #
    # @example In a Rack app (raw Enumerator)
    #   stream = Ask::Agent::Streaming.run(session, prompt)
    #   [200, { "Content-Type" => "text/event-stream" }, stream]
    #
    # @example With custom event mapping
    #   stream = Ask::Agent::Streaming.run(session, prompt) do |event|
    #     case event
    #     when Events::TextDelta
    #       { type: "delta", data: { content: event.content } }
    #     when Events::ToolExecutionStart
    #       { type: "tool_start", data: { name: event.name, id: event.id } }
    #     else
    #       nil # skip unhandled events
    #     end
    #   end
    module Streaming
      DEFAULT_EVENT_MAP = {
        Events::TextDelta => "delta",
        Events::ThinkingDelta => "thinking",
        Events::ToolCallDelta => "tool_call_delta",
        Events::ToolExecutionStart => "tool_start",
        Events::ToolExecutionUpdate => "tool_update",
        Events::ToolExecutionEnd => "tool_end",
        Events::SessionEnd => "done",
        Events::Error => "error"
      }.freeze

      class << self
        # Run an agent session and stream events as SSE-formatted strings.
        #
        # Two modes:
        #
        # 1. **No block** — returns a Rack-compatible Enumerator that yields
        #    raw SSE strings: "data: {\"type\":\"delta\",\"content\":\"...\"}\n\n"
        #
        # 2. **With block** — calls the block for each event with
        #    `(event_type_string, data_hash)`. The block is responsible for
        #    writing/handling the data. This mode is designed for use with
        #    Rails' `ActionController::Live::SSE#write`.
        #
        # @param session [Session] the agent session to run
        # @param prompt [String] the user's message
        # @param event_map [Hash<Class, String>] optional custom event-to-type mapping
        # @yield [type, data] called for each event (only in block mode)
        # @yieldparam type [String] the SSE event type name
        # @yieldparam data [Hash] the event data payload
        # @return [Enumerator, nil] Enumerator in no-block mode, nil in block mode
        def run(session, prompt, event_map: {}, &block)
          mapping = DEFAULT_EVENT_MAP.merge(event_map)

          if block
            run_with_block(session, prompt, mapping, &block)
            nil
          else
            run_with_enumerator(session, prompt, mapping)
          end
        end

        private

        def run_with_block(session, prompt, mapping)
          errors = []

          session.on_event do |event|
            type = event_type(event, mapping)
            data = event_data(event)
            next unless type

            yield(type, data)
          end

          # Emit start event
          yield("start", { session_id: session.id })

          session.run(prompt)

          # If errors accumulated during tool execution, emit them
          errors.each { |err| yield("error", { message: err }) }
        rescue => e
          yield("error", { message: e.message })
        end

        def run_with_enumerator(session, prompt, mapping)
          Enumerator.new do |yielder|
            errors = []

            session.on_event do |event|
              type = event_type(event, mapping)
              data = event_data(event)
              next unless type

              yielder << sse_line(type, data)
            end

            # Emit start event
            yielder << sse_line("start", { session_id: session.id })

            session.run(prompt)

            errors.each { |err| yielder << sse_line("error", { message: err }) }

            yielder << sse_line("close", {})
          rescue => e
            yielder << sse_line("error", { message: e.message })
          ensure
            yielder << sse_line("close", {})
          end
        end

        def event_type(event, mapping)
          # Check for a direct class match
          return mapping[event.class] if mapping.key?(event.class)

          # Check for a superclass match (e.g. ToolExecutionStart is a kind of event)
          event.class.ancestors.each do |ancestor|
            return mapping[ancestor] if mapping.key?(ancestor)
          end

          nil
        end

        def event_data(event)
          case event
          when Events::TextDelta
            { content: event.content }
          when Events::ThinkingDelta
            { content: event.content }
          when Events::ToolCallDelta
            { name: event.name, arguments: event.arguments, id: event.id }
          when Events::ToolExecutionStart
            { name: event.name, id: event.id, args: safe_args(event.arguments) }
          when Events::ToolExecutionUpdate
            { id: event.id, partial_result: event.partial_result.to_s.truncate(200) }
          when Events::ToolExecutionEnd
            { name: event.name, id: event.id, duration_ms: event.duration_ms, is_error: event.is_error }
          when Events::SessionEnd
            { turn_count: event.turn_count, tool_calls_made: event.tool_calls_made,
              input_tokens: event.input_tokens, output_tokens: event.output_tokens,
              cost: event.cost }
          when Events::SessionStart
            {}
          when Events::Error
            { message: event.error, recoverable: event.recoverable }
          else
            {}
          end
        end

        def sse_line(type, data)
          payload = data.merge(type: type)
          "data: #{JSON.generate(payload)}\n\n"
        end

        def safe_args(args)
          return {} unless args.is_a?(Hash)

          safe = args.dup
          %w[password secret token api_key key auth_token access_token sql command].each do |sensitive|
            safe[sensitive] = "[REDACTED]" if safe.key?(sensitive)
          end
          safe
        end
      end
    end
  end
end
