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
end
