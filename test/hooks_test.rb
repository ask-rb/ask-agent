# frozen_string_literal: true

require "ostruct"
require_relative "test_helper"

class HooksTest < Minitest::Test
  def setup
    @call = OpenStruct.new(name: "test_tool", id: "call_1", arguments: {})
  end

  def test_empty_hooks_return_nil
    hooks = Ask::Agent::Hooks.new
    assert_nil hooks.run_before_tool(@call, {})
    assert_nil hooks.run_after_tool(@call, {}, {})
  end

  def test_before_tool_can_block
    hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :block, reason: "Not allowed" }
    })
    result = hooks.run_before_tool(@call, {})
    assert_equal :block, result[:action]
  end

  def test_before_tool_proceed_returns_hash
    hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :proceed }
    })
    result = hooks.run_before_tool(@call, {})
    assert_equal({ action: :proceed }, result)
  end

  def test_before_tool_short_circuit
    hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :short_circuit, result: { output: "mocked" } }
    })
    result = hooks.run_before_tool(@call, {})
    assert_equal :short_circuit, result[:action]
  end

  def test_after_tool_can_block
    blocked = false
    hooks = Ask::Agent::Hooks.new(after_tool: ->(call, result, ctx) {
      blocked = true
      { action: :block }
    })
    result = hooks.run_after_tool(@call, {}, {})
    assert_equal :block, result[:action]
    assert blocked
  end

  def test_after_tool_can_transform
    hooks = Ask::Agent::Hooks.new(after_tool: ->(call, result, ctx) {
      { action: :transform, result: { output: "transformed" } }
    })
    result = hooks.run_after_tool(@call, {}, {})
    assert_equal :transform, result[:action]
  end

  def test_multiple_before_hooks_stop_at_block
    calls = []
    hooks = Ask::Agent::Hooks.new(before_tool: [
      ->(call, ctx) { calls << :first; { action: :proceed } },
      ->(call, ctx) { calls << :second; { action: :block, reason: "no" } },
      ->(call, ctx) { calls << :third }
    ])
    hooks.run_before_tool(@call, {})
    assert_equal %i[first second], calls
  end
end
