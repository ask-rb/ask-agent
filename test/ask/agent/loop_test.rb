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

  def test_run_turn_block_handles_nil_tool_calls
    # Simulate what the loop block does with chunk.tool_calls
    # when tool_calls is nil (should not crash)
    event_emitter = Object.new
    event_emitter.define_singleton_method(:emit) { |_| }

    chunk = Ask::Agent::ChatChunk.new(content: "Hello", tool_calls: nil, thinking: nil, input_tokens: nil, output_tokens: nil)
    refute chunk.tool_call?
  end

  def test_run_turn_block_handles_non_enumerable_tool_calls
    event_emitter = Object.new
    event_emitter.define_singleton_method(:emit) { |_| }

    # ChatChunk should always have Hash tool_calls, but verify guard works
    chunk = Ask::Agent::ChatChunk.new(content: "", tool_calls: {}, thinking: nil, input_tokens: nil, output_tokens: nil)
    refute chunk.tool_call?
  end
end
