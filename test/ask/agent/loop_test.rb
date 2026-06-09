# frozen_string_literal: true

require_relative "../../test_helper"

class LoopTest < Minitest::Test
  def setup
    @loop = Ask::Agent::Loop.new(max_turns: 5)
  end

  def test_initial_turn_count
    assert_equal 0, @loop.turn_count
  end

  def test_reset
    @loop.instance_variable_set(:@turn_count, 3)
    @loop.reset!
    assert_equal 0, @loop.turn_count
  end
end
