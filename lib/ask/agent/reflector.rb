# frozen_string_literal: true

module Ask
  module Agent
    class Reflector
      attr_reader :reflection_count

      def initialize(model:, max_reflections: 1)
        @model = model
        @max_reflections = max_reflections
        @reflection_count = 0
      end

      def reflect?(tool_calls_made)
        return false if @reflection_count >= @max_reflections
        tool_calls_made > 0
      end

      def evaluate(response:, event_emitter:)
        return { decision: :deliver } unless response

        event_emitter.emit(Events::ReflectionStart.new(reflection_number: @reflection_count + 1))

        result = build_eval_chat.ask(reflection_prompt(response)) do |chunk|
          if chunk.content.to_s.strip.length > 0
            event_emitter.emit(Events::ReflectionDelta.new(content: chunk.content))
          end
        end

        decision = parse_decision(result.content.to_s)

        event_emitter.emit(Events::ReflectionEnd.new(
          decision: decision[:decision],
          feedback: decision[:feedback]
        ))

        @reflection_count += 1
        decision
      end

      def reset!
        @reflection_count = 0
      end

      private

      def reflection_prompt(response)
        <<~PROMPT.strip
          Evaluate this assistant response. Is it accurate, complete, and helpful?
          Reply with JSON only — no other text:
          {"decision": "deliver"} or {"decision": "improve", "feedback": "<what to fix>"}

          Response: #{response}
        PROMPT
      end

      def parse_decision(text)
        parsed = JSON.parse(text)
        {
          decision: parsed["decision"] == "improve" ? :improve : :deliver,
          feedback: parsed["feedback"]
        }
      rescue JSON::ParserError
        { decision: :deliver, feedback: nil }
      end

      def build_eval_chat
        model_id = model_id_from(@model)
        Ask::Agent::Chat.new(model: model_id)
      end

      def model_id_from(model)
        case model
        when Ask::Agent::Chat then model.model.to_s
        when String then model
        else model.to_s
        end
      end
    end
  end
end
