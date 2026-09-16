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

      def run_turn(chat:, message:, tools:, tool_executor:, compactor:, hooks:, event_emitter:, session_id: nil, persist: nil, tool_call_repair: nil, steer_source: nil, attachments: nil)
        raise MaxTurnsExceeded if @turn_count >= @max_turns

        event_emitter.emit(Events::TurnStart.new)

        response = chat.ask(message, attachments: attachments) do |chunk|
          # Empty, not blank: providers stream whitespace as its own chunk,
          # and dropping those glues the words around it together — "the
          # balance is due 45 days" arrives as "due45 days", "Grade 4" as
          # "Grade4". A space is content.
          unless chunk.content.to_s.empty?
            event_emitter.emit(Events::TextDelta.new(content: chunk.content))
          end

          if chunk.respond_to?(:thinking) && !chunk.thinking.to_s.empty?
            event_emitter.emit(Events::ThinkingDelta.new(content: chunk.thinking))
          end

          if chunk.tool_call?
            calls = chunk.tool_calls
            if calls.respond_to?(:each)
              calls.each do |id, tc|
                event_emitter.emit(Events::ToolCallDelta.new(
                  name: tc.name, arguments: tc.arguments, id: tc.id
                ))
              end
            end
          end
        end

        @last_input_tokens = response.input_tokens
        @last_output_tokens = response.output_tokens
        @last_cost = response.cost

        event_emitter.emit(Events::MessageEnd.new(tool_calls: response.tool_call?))
        @turn_count += 1

        # Barge-in abort: stop as soon as the in-flight LLM call ends — no
        # tool execution, no follow-up turns. The reply so far is returned
        # (the caller has already moved on).
        if aborted?(event_emitter)
          @consecutive_tool_turns = 0
          return response.content.to_s
        end

        # Check if there are any tool calls (user-executed or provider-executed)
        has_tool_calls = response.tool_call? || (response.tool_results&.any? == true)

        unless has_tool_calls
          @consecutive_tool_turns = 0
          return response.content.to_s
        end

        @consecutive_tool_turns += 1

        provider_results = response.tool_results || {}
        all_tool_results = []

        # Add provider-executed tool results directly to conversation
        provider_results.each do |id, result|
          chat.add_message(role: :tool, content: result[:message].to_s, tool_call_id: id)
          all_tool_results << {
            tool_name: result[:tool_name] || id,
            message: result[:message].to_s,
            status: result[:status] || "success",
            provider_executed: true
          }
        end

        # Determine which tool calls still need local execution
        user_tool_calls = response.tool_calls.reject { |id, _| provider_results.key?(id) }

        if user_tool_calls.any?
          # Repair malformed calls (unparseable arguments, unknown tool
          # names) with one internal LLM round-trip before executing.
          user_tool_calls = repair_malformed_calls(user_tool_calls, tools, chat, event_emitter, tool_call_repair)

          # Execute user tool calls locally
          # Respect the session's parallel_tools setting: parallel tools run
          # in threads (with the caller's thread-local context inherited);
          # sequential tools run in the caller thread so per-request context
          # (e.g. Rails CurrentAttributes) is visible without any copying.
          # Pending (async) tool results skip the chat message — it is added
          # when the background work completes.
          user_results = tool_executor.execute(
            user_tool_calls, tools, hooks: hooks, event_emitter: event_emitter,
            session_id: session_id,
            result_callback: lambda do |tool_call_id, result|
              tc = user_tool_calls[tool_call_id]
              next unless tc
              next if result[:status] == "pending"

              chat.add_message(role: :tool, content: result[:message].to_s, tool_call_id: tool_call_id) if tc
            end
          )
          all_tool_results.concat(user_results)
        end

        # Async tools: hand the turn back with the interim reply. The
        # session registers the pending calls; completions arrive later via
        # Session#complete_pending_tool.
        pending_calls = all_tool_results.select { |r| r[:status] == "pending" }
        unless pending_calls.empty?
          pending_calls.each do |pending_result|
            if event_emitter.respond_to?(:register_pending_tool)
              event_emitter.register_pending_tool(
                pending_result[:tool_call_id], pending_result
              )
            end
          end
          @consecutive_tool_turns = 0
          return response.content.to_s
        end

        # Check loop detection
        if loop_detected?(all_tool_results)
          raise LoopDetected, all_tool_results.last[:tool_name]
        end

        if @consecutive_tool_turns >= @max_consecutive_tool_turns
          summary = all_tool_results.map { |r| truncate(r[:message], 80) }.first(2).join("; ")
          return "Based on my investigation: #{summary}"
        end

        event_emitter.emit(Events::TurnEnd.new(
          tool_results: all_tool_results,
          turn_number: @turn_count,
          input_tokens: @last_input_tokens,
          output_tokens: @last_output_tokens,
          cost: @last_cost
        ))

        if compactor && compactor.should_compact?
          compactor.run(event_emitter: event_emitter)
        end

        # Persist after each turn so mid-session crashes don't lose progress
        persist&.call

        raise MaxTurnsExceeded if @turn_count >= @max_turns

        # Aborted while tools ran? Skip the follow-up LLM call.
        return response.content.to_s if aborted?(event_emitter)

        # Recursive call — LLM processes tool results. When a steer source
        # is provided, queued steer messages become the next user message
        # instead of an empty continuation.
        run_turn(
          chat: chat,
          message: steer_source ? steer_source.call.to_s : "",
          tools: tools,
          tool_executor: tool_executor,
          compactor: compactor,
          hooks: hooks,
          event_emitter: event_emitter,
          session_id: session_id,
          persist: persist,
          tool_call_repair: tool_call_repair,
          steer_source: steer_source
        )
      end

      def reset!
        @turn_count = 0
        @recent_results = []
        @loop_detected = false
      end

      private

      # Repair malformed tool calls before execution. Calls with corrected
      # versions execute in place of the originals (same ids); calls the
      # model could not correct are dropped — the model saw them in the
      # repair prompt. Best-effort: a failing repair round-trip drops the
      # malformed calls instead of failing the turn.
      def repair_malformed_calls(user_tool_calls, tools, chat, event_emitter, tool_call_repair)
        return user_tool_calls if tool_call_repair.nil? || user_tool_calls.empty?

        repairer = if tool_call_repair == true
          @tool_call_repair ||= ToolCallRepair.new
        elsif tool_call_repair.respond_to?(:call)
          ToolCallRepair.new(tool_call_repair)
        end
        return user_tool_calls unless repairer

        malformed, _valid = user_tool_calls.partition do |_id, tc|
          ToolCallRepair.repair_info(tc, tools)
        end
        return user_tool_calls if malformed.empty?

        corrections = repairer.call(chat: chat, calls: malformed.to_h, tools: tools)

        corrections.each do |id, corrected|
          event_emitter.emit(Events::ToolCallRepaired.new(
            name: corrected.name,
            id: id,
            original_arguments: user_tool_calls[id].arguments,
            corrected_arguments: corrected.arguments
          ))
          user_tool_calls[id] = corrected
        end

        malformed_ids = malformed.map(&:first)
        user_tool_calls.reject! { |id, _| malformed_ids.include?(id) && !corrections.key?(id) }
        user_tool_calls
      end

      # Whether the session asked the loop to stop (barge-in). Emitters that
      # don't support aborting (plain stubs) are treated as never aborted.
      def aborted?(event_emitter)
        event_emitter.respond_to?(:abort_requested?) && event_emitter.abort_requested?
      end

      # Truncate a string for summaries without depending on ActiveSupport's
      # String#truncate (which is not loaded by a bare `require "ask-agent"`).
      def truncate(text, length)
        s = text.to_s
        return s if s.length <= length

        "#{s[0, length - 3]}..."
      end

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
