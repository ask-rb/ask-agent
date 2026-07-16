# frozen_string_literal: true

module Ask
  module Agent
    class Loop
      LOOP_DETECTION_WINDOW = 3
      @max_consecutive_tool_turns = 6

      attr_reader :turn_count, :last_input_tokens, :last_output_tokens, :last_cost

      def initialize(max_turns: 25, max_consecutive_tool_turns: 6)
        @max_turns = max_turns
        @turn_count = 0
        @recent_results = []
        @loop_detected = false
        @consecutive_tool_turns = 0
      @max_consecutive_tool_turns = max_consecutive_tool_turns
      end

      def run_turn(chat:, message:, tools:, tool_executor:, compactor:, hooks:, event_emitter:, session_id: nil)
        raise MaxTurnsExceeded if @turn_count >= @max_turns

        event_emitter.emit(Events::TurnStart.new)

        response = chat.ask(message) do |chunk|
          if chunk.content.to_s.strip.length > 0
            event_emitter.emit(Events::TextDelta.new(content: chunk.content))
          end

          if chunk.tool_call?
            chunk.tool_calls.each do |id, tc|
              event_emitter.emit(Events::ToolCallDelta.new(
                name: tc.name, arguments: tc.arguments, id: tc.id
              ))
            end
          end
        end

        @last_input_tokens = response.input_tokens
        @last_output_tokens = response.output_tokens
        @last_cost = response.cost

        event_emitter.emit(Events::MessageEnd.new(tool_calls: response.tool_call?))
        @turn_count += 1

        unless response.tool_call?
          @consecutive_tool_turns = 0
          return response.content.to_s
        end

        @consecutive_tool_turns += 1

        # Execute tools with concurrent result streaming
        tool_results = tool_executor.execute_parallel(
          response.tool_calls, tools, hooks, event_emitter, ToolAbortController.new
        ) do |tool_call_id, result|
          # Add each tool result as it completes (concurrent streaming)
          tc = response.tool_calls[tool_call_id]
          chat.add_message(role: :tool, content: result[:message].to_s, tool_call_id: tool_call_id) if tc
        end

        # Check loop detection
        if loop_detected?(tool_results)
          raise LoopDetected, tool_results.last[:tool_name]
        end

        if @consecutive_tool_turns >= @max_consecutive_tool_turns
          summary = tool_results.map { |r| r[:message].to_s.truncate(80) }.first(2).join("; ")
          return "Based on my investigation: #{summary}"
        end

        event_emitter.emit(Events::TurnEnd.new(
          tool_results: tool_results,
          turn_number: @turn_count,
          input_tokens: @last_input_tokens,
          output_tokens: @last_output_tokens,
          cost: @last_cost
        ))

        if compactor && compactor.should_compact?
          compactor.run(event_emitter: event_emitter)
        end

        raise MaxTurnsExceeded if @turn_count >= @max_turns

        # Recursive call — LLM processes tool results
        run_turn(
          chat: chat,
          message: "",
          tools: tools,
          tool_executor: tool_executor,
          compactor: compactor,
          hooks: hooks,
          event_emitter: event_emitter,
          session_id: session_id
        )
      end

      def reset!
        @turn_count = 0
        @recent_results = []
        @loop_detected = false
      end

      private

      def loop_detected?(results)
        return false if results.empty?

        results.each do |result|
          signature = [result[:tool_name], result[:message].to_s.strip]
          @recent_results << signature
          @recent_results.shift if @recent_results.size > LOOP_DETECTION_WINDOW

          recent = @recent_results.last(LOOP_DETECTION_WINDOW)
          if recent.size >= LOOP_DETECTION_WINDOW && recent.uniq.size == 1
            @loop_detected = true
            return true
          end
        end
        false
      end
    end
  end
end
