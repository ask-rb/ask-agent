# frozen_string_literal: true

require_relative "../../test_helper"

class EvaluatorTest < Minitest::Test
  include AgentTestHelpers

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "claude-sonnet-4", provider: "anthropic"))
    @evaluator = Ask::Agent::Evaluator.new(model: "claude-sonnet-4")
  end

  # --- Initialization ---

  def test_create_evaluator_with_model
    assert_equal "claude-sonnet-4", @evaluator.model
  end

  def test_create_evaluator_with_custom_rubric
    rubric = [
      Ask::Agent::Evaluator::Dimension.new(name: "custom", description: "A custom dimension", weight: 1)
    ]
    evaluator = Ask::Agent::Evaluator.new(model: "gpt-4o", rubric: rubric)
    assert_equal 1, evaluator.rubric.size
    assert_equal "custom", evaluator.rubric.first.name
  end

  def test_default_rubric_has_expected_dimensions
    names = @evaluator.rubric.map(&:name)
    assert_includes names, "correctness"
    assert_includes names, "completeness"
    assert_includes names, "verification"
    assert_includes names, "scope"
    assert_includes names, "clarity"
  end

  def test_default_rubric_is_frozen
    assert @evaluator.rubric.frozen?
  end

  def test_dimension_requires_name_and_description
    dim = Ask::Agent::Evaluator::Dimension.new(name: "test", description: "test dimension", weight: 1)
    assert_equal "test", dim.name
    assert_equal "test dimension", dim.description
    assert_equal 1, dim.weight
  end

  def test_dimension_defaults_weight_to_1
    dim = Ask::Agent::Evaluator::Dimension.new(name: "test", description: "test dimension")
    assert_equal 1, dim.weight
  end

  # --- Result ---

  def test_result_accept_predicate
    result = Ask::Agent::Evaluator::Result.new(decision: :accept, feedback: "", scores: {}, evidence: [])
    assert result.accept?
    refute result.revise?
    refute result.block?
  end

  def test_result_revise_predicate
    result = Ask::Agent::Evaluator::Result.new(decision: :revise, feedback: "fix it", scores: {}, evidence: [])
    assert result.revise?
    refute result.accept?
    refute result.block?
  end

  def test_result_block_predicate
    result = Ask::Agent::Evaluator::Result.new(decision: :block, feedback: "wrong", scores: {}, evidence: [])
    assert result.block?
    refute result.accept?
    refute result.revise?
  end

  # --- evaluate returns accept ---

  def test_evaluate_returns_accept_when_model_says_accept
    chat_stub = build_eval_chat_stub('{"decision":"accept","feedback":"","scores":{"correctness":2},"evidence":["Looks good"]}')
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    result = @evaluator.evaluate(goal: "Do the thing", response: "Did the thing")

    assert result.accept?
    assert_equal "", result.feedback
    assert_equal 2, result.scores[:correctness]
    assert_includes result.evidence, "Looks good"
  end

  # --- evaluate returns revise ---

  def test_evaluate_returns_revise_when_model_says_revise
    chat_stub = build_eval_chat_stub('{"decision":"revise","feedback":"Add error handling","scores":{"correctness":1},"evidence":["Missing edge case"]}')
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    result = @evaluator.evaluate(goal: "Do the thing", response: "Did the thing")

    assert result.revise?
    assert_equal "Add error handling", result.feedback
    assert_equal 1, result.scores[:correctness]
  end

  # --- evaluate returns block ---

  def test_evaluate_returns_block_when_model_says_block
    chat_stub = build_eval_chat_stub('{"decision":"block","feedback":"Completely wrong approach","scores":{"correctness":0},"evidence":["Does not address goal"]}')
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    result = @evaluator.evaluate(goal: "Do the thing", response: "Did the wrong thing")

    assert result.block?
    assert_equal "Completely wrong approach", result.feedback
    assert_equal 0, result.scores[:correctness]
  end

  # --- event emission ---

  def test_evaluate_emits_start_and_end_events
    chat_stub = build_eval_chat_stub('{"decision":"accept","feedback":"","scores":{"correctness":2},"evidence":[]}')
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    events = []
    emitter = Object.new
    emitter.define_singleton_method(:emit) { |e| events << e }

    @evaluator.evaluate(goal: "test", response: "test", event_emitter: emitter)

    assert events.any? { |e| e.is_a?(Ask::Agent::Events::EvaluationStart) }
    assert events.any? { |e| e.is_a?(Ask::Agent::Events::EvaluationEnd) }
  end

  def test_evaluate_emits_delta_during_streaming
    chat_stub = build_eval_chat_stub('{"decision":"accept","feedback":"","scores":{},"evidence":[]}')
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    deltas = []
    emitter = Object.new
    emitter.define_singleton_method(:emit) { |e| deltas << e if e.is_a?(Ask::Agent::Events::EvaluationDelta) }

    @evaluator.evaluate(goal: "test", response: "test", event_emitter: emitter)

    assert deltas.any?, "should emit at least one EvaluationDelta"
  end

  # --- eval with custom rubric ---

  def test_evaluate_uses_custom_rubric
    rubric = [
      Ask::Agent::Evaluator::Dimension.new(name: "performance", description: "Is it fast?", weight: 2)
    ]
    evaluator = Ask::Agent::Evaluator.new(model: "gpt-4o", rubric: rubric)

    chat_stub = build_eval_chat_stub('{"decision":"accept","feedback":"","scores":{"performance":2},"evidence":[]}')
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    result = evaluator.evaluate(goal: "Be fast", response: "It is fast")

    assert result.accept?
    assert_equal 2, result.scores[:performance]
  end

  # --- malformed JSON fallback ---

  def test_evaluate_falls_back_to_accept_on_malformed_json
    chat_stub = build_eval_chat_stub("this is not json")
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    result = @evaluator.evaluate(goal: "Do the thing", response: "Did the thing")

    # fallback is accept — don't block on parse errors
    assert result.accept?
    assert_equal "", result.feedback
  end

  def test_evaluate_recovers_json_from_extra_text
    chat_stub = build_eval_chat_stub("Here is my evaluation:\n\n{\"decision\":\"accept\",\"feedback\":\"\",\"scores\":{\"correctness\":2},\"evidence\":[\"Good\"]}\n\n---")
    Ask::Agent::Chat.stubs(:new).returns(chat_stub)

    result = @evaluator.evaluate(goal: "Do the thing", response: "Did the thing")

    assert result.accept?
    assert_equal 2, result.scores[:correctness]
  end

  private

  def build_eval_chat_stub(json_response)
    model_stub = OpenStruct.new(id: "claude-sonnet-4", to_s: "claude-sonnet-4")
    chat_stub = OpenStruct.new(model: model_stub, model_id: "claude-sonnet-4")
    chat_stub.define_singleton_method(:with_instructions) { |*| self }
    chat_stub.define_singleton_method(:add_message) { |*| }
    chat_stub.define_singleton_method(:messages) { [] }
    chat_stub.define_singleton_method(:reset_messages!) { nil }
    chat_stub.define_singleton_method(:ask) do |_message, &block|
      if block
        chunk = Ask::Agent::ChatChunk.new(
          content: json_response, tool_calls: {},
          thinking: nil, input_tokens: nil, output_tokens: nil
        )
        block.call(chunk)
      end
      Ask::Agent::ResponseMessage.new(content: json_response)
    end
    chat_stub
  end
end
