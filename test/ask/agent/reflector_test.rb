# frozen_string_literal: true

require_relative "../../test_helper"

class ReflectorTest < Minitest::Test
  def setup
    @reflector = Ask::Agent::Reflector.new(model: "gpt-4o", max_reflections: 2)
  end

  def test_initial_reflection_count_zero
    assert_equal 0, @reflector.reflection_count
  end

  def test_reflect_when_no_tool_calls
    refute @reflector.reflect?(0)
  end

  def test_reflect_when_tool_calls_made
    assert @reflector.reflect?(1)
  end

  def test_reflect_respects_max_reflections
    @reflector.instance_variable_set(:@reflection_count, 2)
    refute @reflector.reflect?(5)
  end

  def test_reset_clears_count
    @reflector.instance_variable_set(:@reflection_count, 5)
    @reflector.reset!
    assert_equal 0, @reflector.reflection_count
  end

  def test_model_id_from_string
    id = @reflector.send(:model_id_from, "gpt-4o-mini")
    assert_equal "gpt-4o-mini", id
  end

  def test_model_id_from_chat_object
    chat = Ask::Agent::Chat.new(model: "claude-sonnet-4")
    id = @reflector.send(:model_id_from, chat)
    assert_equal "claude-sonnet-4", id
  end

  def test_model_id_from_unknown_uses_to_s
    obj = Object.new
    obj.define_singleton_method(:to_s) { "custom-model" }
    id = @reflector.send(:model_id_from, obj)
    assert_equal "custom-model", id
  end

  def test_parse_decision_deliver
    decision = @reflector.send(:parse_decision, '{"decision": "deliver"}')
    assert_equal :deliver, decision[:decision]
  end

  def test_parse_decision_improve
    decision = @reflector.send(:parse_decision, '{"decision": "improve", "feedback": "add more detail"}')
    assert_equal :improve, decision[:decision]
    assert_equal "add more detail", decision[:feedback]
  end

  def test_parse_decision_malformed_json
    decision = @reflector.send(:parse_decision, "not json")
    assert_equal :deliver, decision[:decision]
  end

  def test_reflection_prompt_includes_response
    prompt = @reflector.send(:reflection_prompt, "The answer is 42.")
    assert_includes prompt, "The answer is 42."
  end
end
