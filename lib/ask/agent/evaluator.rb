# frozen_string_literal: true

module Ask
  module Agent
    class Evaluator
      # Structured result from an evaluation.
      # - decision :accept — response meets the goal
      #           :revise — response needs improvement (feedback provided)
      #           :block  — response is fundamentally wrong (hard stop)
      # - feedback actionable text the generator can use to improve
      # - scores   hash of dimension name => score (0, 1, or 2)
      # - evidence array of specific evidence strings
      Result = Data.define(:decision, :feedback, :scores, :evidence) do
        def accept? = decision == :accept
        def revise? = decision == :revise
        def block?  = decision == :block
      end

      # A single dimension in the evaluation rubric.
      Dimension = Data.define(:name, :description, :weight) do
        def initialize(name:, description:, weight: 1)
          super(name: name, description: description, weight: weight)
        end
      end

      # Default rubric borrowed from the course's evaluator-rubric template.
      DEFAULT_DIMENSIONS = [
        Dimension.new(name: "correctness",  description: "Does the output match the requested goal?",                               weight: 3),
        Dimension.new(name: "completeness", description: "Are all aspects of the goal addressed?",                                  weight: 2),
        Dimension.new(name: "verification", description: "Is there evidence that the output actually works?",                        weight: 2),
        Dimension.new(name: "scope",        description: "Did it stay within the defined boundaries without overreaching?",          weight: 1),
        Dimension.new(name: "clarity",      description: "Is the output clear, well-structured, and maintainable?",                  weight: 1),
      ].freeze

      # How many times the evaluator may retry on a malformed response.
      MAX_EVAL_RETRIES = 2

      attr_reader :model, :rubric

      # @param model [String] the model id to use for evaluation (should differ from the generator's model)
      # @param rubric [Array<Dimension>] the rubric dimensions to evaluate against
      def initialize(model:, rubric: DEFAULT_DIMENSIONS)
        @model = model
        @rubric = rubric
      end

      # Evaluate a response against a goal.
      #
      # @param goal [String] what the generator was asked to do
      # @param response [String] what the generator produced
      # @param event_emitter [#emit, nil] optional event emitter for streaming evaluation
      # @return [Result] structured evaluation result
      def evaluate(goal:, response:, event_emitter: nil)
        event_emitter&.emit(Events::EvaluationStart.new(dimensions: @rubric.map(&:name)))

        chat = build_chat
        chat.with_instructions(evaluation_prompt(goal))

        accumulated = +""
        chat.ask(response.to_s) do |chunk|
          if chunk.content.to_s.strip.length > 0
            accumulated << chunk.content.to_s
            event_emitter&.emit(Events::EvaluationDelta.new(content: chunk.content.to_s))
          end
        end

        result = parse_result(accumulated)
        event_emitter&.emit(Events::EvaluationEnd.new(
          decision: result.decision,
          feedback: result.feedback,
          scores: result.scores,
          evidence: result.evidence
        ))

        result
      end

      private

      def build_chat
        Chat.new(model: @model)
      end

      def evaluation_prompt(goal)
        dimensions_text = @rubric.each_with_index.map { |d, i|
          weight_label = d.weight > 1 ? " (weight: #{d.weight}x)" : ""
          "#{i + 1}. **#{d.name}**#{weight_label} — #{d.description}"
        }.join("\n")

        <<~PROMPT
          You are an independent evaluator. Your job is to assess whether a response
          successfully achieves the given goal. You are NOT the agent that produced
          this response — you are a neutral, objective judge.

          ## Goal

          #{goal}

          ## Rubric

          Evaluate the response against these dimensions:

          #{dimensions_text}

          For each dimension, assign a score:
          - **0** = fails completely
          - **1** = partially meets
          - **2** = fully meets

          Then provide:
          - A final **decision**: "accept" (response meets the goal), "revise" (needs specific improvements), or "block" (fundamentally wrong — cannot be fixed with revisions)
          - **Actionable feedback** the generator can use to improve (if decision is revise or block)
          - **Concrete evidence** for your scores

          Return valid JSON only — no other text:
          {
            "scores": { "correctness": 2, "completeness": 1, ... },
            "decision": "accept",
            "feedback": "Specific feedback here (or empty string if accepted)",
            "evidence": ["Evidence point 1", "Evidence point 2"]
          }
        PROMPT
      end

      def parse_result(text)
        json = extract_json(text)
        return default_fallback unless json

        scores = json["scores"] || {}

        decision = case json["decision"].to_s.strip.downcase
                   when "revise" then :revise
                   when "block"  then :block
                   else :accept
                   end

        Result.new(
          decision: decision,
          feedback: json["feedback"].to_s.strip,
          scores: scores.transform_keys(&:to_sym),
          evidence: Array(json["evidence"])
        )
      end

      def extract_json(text)
        # Try direct parse first
        JSON.parse(text.strip)
      rescue JSON::ParserError
        # Fall back to extracting the first JSON object
        match = text.match(/\{.*\}/m)
        match ? JSON.parse(match[0]) : nil
      end

      def default_fallback
        Result.new(
          decision: :accept,
          feedback: "",
          scores: {},
          evidence: []
        )
      end
    end
  end
end
