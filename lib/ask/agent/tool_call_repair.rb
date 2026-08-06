# frozen_string_literal: true

require "json"

module Ask
  module Agent
    # Repairs malformed tool calls before they execute.
    #
    # When a model emits a tool call with unparseable arguments or an unknown
    # tool name, execution currently fails and the model burns a turn seeing
    # the error. Repair intercepts those calls before execution, asks the
    # model to re-emit them corrected (one internal LLM round-trip), and
    # executes the corrected versions — remapped to the original call ids so
    # tool results stay consistent with the conversation history.
    #
    # Enable with `Session.new(tool_call_repair: true)` for the built-in
    # repair prompt, or pass a callable for full control:
    #
    #   Session.new(tool_call_repair: ->(chat, calls, tools) {
    #     { calls.keys.first => ToolCallInfo.new(
    #         id: calls.keys.first, name: "bash", arguments: "{}"
    #       ) }
    #   })
    #
    # The callable receives the chat, the malformed calls hash (id =>
    # ToolCallInfo), and the available tools; it returns a hash of
    # corrections keyed by the ORIGINAL call ids. Calls without a correction
    # are dropped — the model saw them in the prompt and declined to fix
    # them.
    class ToolCallRepair
      # @param tool_call [ToolCallInfo]
      # @param tools [Array<Object>]
      # @return [String, nil] why the call is repairable, or nil when it is
      #   well-formed and executable
      def self.repair_info(tool_call, tools)
        unless tools.any? { |t| t.respond_to?(:name) && t.name == tool_call.name }
          return "unknown tool '#{tool_call.name}'"
        end

        args = tool_call.arguments
        return nil if args.is_a?(Hash)

        parsed = JSON.parse(args.to_s)
        return nil if parsed.is_a?(Hash)

        "arguments must be a JSON object, got #{parsed.class}"
      rescue JSON::ParserError => e
        "arguments are not valid JSON: #{e.message}"
      end

      # @param callable [Proc, nil] custom repair function; nil uses the
      #   built-in repair prompt
      def initialize(callable = nil)
        @callable = callable
      end

      # Ask the model to correct the malformed calls.
      #
      # @param chat [Ask::Agent::Chat] the session chat (history is restored
      #   after the internal round-trip)
      # @param calls [Hash{String => ToolCallInfo}] malformed calls by id
      # @param tools [Array<Object>]
      # @return [Hash{String => ToolCallInfo}] corrections keyed by the
      #   original call ids
      def call(chat:, calls:, tools:)
        if @callable
          normalize(@callable.call(chat, calls, tools))
        else
          built_in(chat, calls, tools)
        end
      end

      private

      def built_in(chat, calls, tools)
        size = chat.messages.size
        response = chat.ask(repair_prompt(calls, tools))
        # Remove the internal repair exchange from the conversation so the
        # history stays clean and the model never sees it.
        chat.messages.slice!(size..)

        corrections = {}
        response.tool_calls.values.each_with_index do |tc, index|
          original_id = calls.keys[index]
          break unless original_id

          corrections[original_id] = ToolCallInfo.new(
            id: original_id, name: tc.name, arguments: tc.arguments
          )
        end
        corrections
      rescue StandardError
        # Repair is best-effort: on any failure, drop the malformed calls
        # rather than failing the turn. Restore history either way.
        chat.messages.slice!(size..) rescue nil
        {}
      end

      # Normalize a custom callable's result to the corrections contract
      # (original id => ToolCallInfo), dropping anything malformed.
      def normalize(result)
        return {} unless result.respond_to?(:each)

        result.each_with_object({}) do |(id, tc), acc|
          next unless tc.respond_to?(:name)

          acc[id] = ToolCallInfo.new(id: id, name: tc.name, arguments: tc.arguments)
        end
      end

      def repair_prompt(calls, tools)
        lines = calls.map.with_index do |(id, tc), i|
          reason = self.class.repair_info(tc, tools) || "invalid"
          "#{i + 1}. call id \"#{id}\", tool \"#{tc.name}\", " \
            "arguments: #{tc.arguments.inspect} — #{reason}"
        end
        tool_list = tools.map { |t| t.respond_to?(:name) ? t.name : t.to_s }.join(", ")

        <<~PROMPT.strip
          Some tool calls from your last message were invalid and could not be executed:
          #{lines.join("\n")}

          Available tools: #{tool_list.empty? ? "(none)" : tool_list}

          Reply by calling the tools again with corrected arguments, in the same order as listed above. Call ONLY the tools listed above that you can correct; if a tool truly does not exist or cannot be corrected, do not call it.
        PROMPT
      end
    end
  end
end
