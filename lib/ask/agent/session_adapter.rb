# frozen_string_literal: true

require "securerandom"
require "ask/session"

module Ask
  module Agent
    # Adapter that bridges an Ask::Agent::Session to an Ask::Session::Host.
    #
    # Maps agent events to event-sourced ask-session events, persists a
    # snapshot at the end of each run, and supports resume from the latest
    # durable snapshot.
    #
    #   adapter = SessionAdapter.create(agent: session, host: host)
    #   result = adapter.run("Hello")
    #
    #   restored = SessionAdapter.resume(agent: session, host: host, session_id: id)
    #   restored.run("Follow up")
    #
    class SessionAdapter
      SNAPSHOT_TYPE = "agent.snapshot"

      # Raised when resume cannot find the ask-session record or its
      # latest snapshot.
      class Error < Ask::Agent::Error; end

      attr_reader :agent, :host, :session_id

      def initialize(agent:, host:, session_id: agent.id, metadata: {}, create: false)
        @agent = agent
        @host = host
        @session_id = session_id
        @current_trace_id = nil
        @current_turn_id = nil
        @current_causation_id = nil

        @host.create(id: @session_id, metadata: metadata) if create

        attach_event_handler
      end

      # Create a new ask-session record and return the adapter.
      #
      # @param agent [Ask::Agent::Session] the agent session
      # @param host [Ask::Session::Host] the session host
      # @param metadata [Hash] session metadata
      # @return [SessionAdapter]
      def self.create(agent:, host:, metadata: {})
        record = host.create(id: agent.id, metadata: metadata)
        new(agent: agent, host: host, session_id: record.id, metadata: metadata, create: false)
      end

      # Attach to an existing ask-session and restore the latest snapshot.
      #
      # Contract: Ask::Session::Host#session raises
      # Ask::Session::NotFoundError for a missing record (it never returns
      # nil); both missing-session and missing-snapshot failures surface as
      # SessionAdapter::Error.
      #
      # @param agent [Ask::Agent::Session] the agent session (will be populated from snapshot)
      # @param host [Ask::Session::Host] the session host
      # @param session_id [String] the ask-session record id
      # @return [SessionAdapter]
      # @raise [SessionAdapter::Error] if the session or snapshot is not found
      def self.resume(agent:, host:, session_id:)
        begin
          host.session(session_id)
        rescue Ask::Session::NotFoundError
          raise Error, "Session not found: #{session_id.inspect}"
        end

        events = host.events(session_id)
        snapshot_event = events.reverse_each.find { |e| e.type == SNAPSHOT_TYPE }
        raise Error, "No snapshot found for session #{session_id.inspect}" unless snapshot_event

        payload = snapshot_event.payload
        messages = payload[:messages] || payload["messages"] || []

        # Validate before mutating the agent so a malformed snapshot cannot
        # leave it half-restored.
        messages.each do |msg|
          role = msg.is_a?(Hash) ? (msg[:role] || msg["role"]) : nil
          raise Error, "Snapshot for session #{session_id.inspect} contains a message without a role" unless role
        end

        agent.instance_variable_set(:@turn_count, payload[:turn_count] || payload["turn_count"] || 0)
        agent.chat.reset_messages!
        messages.each do |msg|
          agent.chat.add_message(
            role: (msg[:role] || msg["role"]).to_sym,
            content: deserialize_content(msg[:content] || msg["content"]),
            tool_call_id: msg[:tool_call_id] || msg["tool_call_id"],
            tool_calls: msg[:tool_calls] || msg["tool_calls"]
          )
        end
        agent.instance_variable_set(:@messages, agent.chat.messages.dup)

        new(agent: agent, host: host, session_id: session_id, create: false)
      end

      # Current trace id for the running trace.
      # @return [String, nil]
      def current_trace_id
        @current_trace_id
      end

      # Current turn identifier (stable per TurnStart).
      # @return [Integer, nil]
      def current_turn_id
        @current_turn_id
      end

      # Run the agent and record events in the ask-session.
      #
      # @param message [String] the user message
      # @param trace_id [String, nil] optional trace id (auto-generated if nil)
      # @param causation_id [String, nil] optional causation id linking to the
      #   event that caused this run
      # @param options [Hash] forwarded to agent.run
      # @return [String] the agent response
      def run(message, trace_id: nil, causation_id: nil, **options)
        @current_trace_id = trace_id || "trace_#{SecureRandom.hex(8)}"
        @current_causation_id = causation_id

        # Record user input as a message event.
        input_event = @host.send_message(
          @session_id,
          content: message.to_s,
          trace_id: @current_trace_id,
          causation_id: @current_causation_id
        )
        @current_causation_id ||= input_event.trace_id

        begin
          result = @agent.run(message, **options)

          # Append snapshot for resume.
          snapshot = build_snapshot
          @host.append(
            @session_id,
            type: SNAPSHOT_TYPE,
            payload: snapshot,
            trace_id: @current_trace_id,
            causation_id: @current_causation_id
          )

          result
        rescue Ask::Agent::Aborted
          @host.append(
            @session_id,
            type: "turn.aborted",
            payload: { turn_id: @current_turn_id },
            trace_id: @current_trace_id,
            causation_id: @current_causation_id
          )
          raise
        rescue => e
          @host.append(
            @session_id,
            type: "turn.failed",
            payload: { error: e.message, error_class: e.class.name },
            trace_id: @current_trace_id,
            causation_id: @current_causation_id
          )
          raise
        ensure
          @current_turn_id = nil
          @current_causation_id = nil
        end
      end

      # Request agent abort without writing a terminal session event.
      def abort
        @agent.abort
      end

      # Close the ask-session (terminal: :closed).
      def close
        @host.close(@session_id)
      end

      # Abort the ask-session (terminal: :aborted).
      def abort_session
        @host.abort(@session_id)
      end

      private

      def attach_event_handler
        @agent.on_event do |event|
          handle_event(event)
        end
      end

      def handle_event(event)
        trace_id = @current_trace_id
        causation_id = @current_causation_id
        turn_id = @current_turn_id

        case event
        when Events::TurnStart
          @current_turn_id = (@current_turn_id || 0) + 1
          turn_id = @current_turn_id
          @host.append(@session_id, type: "turn.started", payload: { turn_id: turn_id }, trace_id: trace_id, causation_id: causation_id)

        when Events::TextDelta
          @host.append(@session_id, type: "model.streaming", payload: { content: event.content, turn_id: turn_id }, trace_id: trace_id, causation_id: causation_id)

        when Events::ThinkingDelta
          @host.append(@session_id, type: "model.thinking", payload: { content: event.content, turn_id: turn_id }, trace_id: trace_id, causation_id: causation_id)

        when Events::ToolExecutionStart
          @host.append(@session_id, type: "tool.use", payload: { tool_name: event.name, arguments: event.arguments, tool_call_id: event.id, turn_id: turn_id }, trace_id: trace_id, causation_id: causation_id)

        when Events::ToolExecutionUpdate
          @host.append(@session_id, type: "tool.delta", payload: { tool_name: event.name, tool_call_id: event.id, partial_result: event.partial_result, turn_id: turn_id }, trace_id: trace_id, causation_id: causation_id)

        when Events::ToolExecutionEnd
          @host.append(@session_id, type: "tool.result", payload: { tool_name: event.name, tool_call_id: event.id, result: event.result, is_error: event.is_error, duration_ms: event.duration_ms, turn_id: turn_id }, trace_id: trace_id, causation_id: causation_id)

        when Events::TodoUpdated
          @host.append(@session_id, type: "todos.updated", payload: { todos: event.todos }, trace_id: trace_id, causation_id: causation_id)

        when Events::PlanProposed
          @host.append(@session_id, type: "plan.proposed", payload: { plan: event.plan }, trace_id: trace_id, causation_id: causation_id)

        when Events::PlanApproved
          @host.append(@session_id, type: "plan.approved", payload: { plan: event.plan }, trace_id: trace_id, causation_id: causation_id)

        when Events::PlanRejected
          @host.append(@session_id, type: "plan.rejected", payload: { plan: event.plan }, trace_id: trace_id, causation_id: causation_id)

        when Events::Error
          @host.append(@session_id, type: "error", payload: { message: event.error, recoverable: event.recoverable }, trace_id: trace_id, causation_id: causation_id)
        end
      end

      def build_snapshot
        {
          messages: (@agent.messages || []).map(&:to_h),
          turn_count: @agent.turn_count || 0
        }
      end

      def self.deserialize_content(content)
        content.is_a?(Array) ? content.map { |block| Ask::Content.from_h(block) } : content
      end
    end
  end
end
