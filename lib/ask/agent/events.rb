# frozen_string_literal: true

module Ask
  module Agent
    module Events
      SessionStart = Data.define
      SessionEnd = Data.define(:result, :turn_count, :tool_calls_made, :input_tokens, :output_tokens, :cost)

      TurnStart = Data.define
      TurnEnd = Data.define(:tool_results, :turn_number, :input_tokens, :output_tokens, :cost)

      MessageStart = Data.define
      TextDelta = Data.define(:content)
      ToolCallDelta = Data.define(:name, :arguments, :id)
      MessageEnd = Data.define(:tool_calls)

      ToolExecutionStart = Data.define(:name, :arguments, :id)
      ToolExecutionUpdate = Data.define(:name, :id, :partial_result)
      ToolExecutionEnd = Data.define(:name, :id, :result, :is_error, :duration_ms)

      CompactionStart = Data.define(:tokens_before, :reason)
      CompactionEnd = Data.define(:tokens_before, :tokens_after, :summary)

      LoopDetected = Data.define(:tool_name, :repeated_count)
      MaxTurnsExceeded = Data.define(:max_turns)

      ReflectionStart = Data.define(:reflection_number)
      ReflectionDelta = Data.define(:content)
      ReflectionEnd = Data.define(:decision, :feedback)

      MetaAgentAnalysis = Data.define(:results, :count)

      Error = Data.define(:error, :recoverable)
    end
  end
end
