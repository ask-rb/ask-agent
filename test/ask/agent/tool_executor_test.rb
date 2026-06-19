# frozen_string_literal: true

require_relative "../../test_helper"

class ToolExecutorTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @tool = FakeTool.new
    @tools = [@tool]
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_execute_empty_calls_returns_empty
    result = @executor.execute({}, @tools, hooks: @hooks, event_emitter: @emitter)
    assert_equal [], result
  end

  def test_execute_tool_call
    calls = { "call_1" => OpenStruct.new(name: "fake_tool", id: "call_1", arguments: {}) }
    result = @executor.execute(calls, @tools, hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, result.length
    assert_equal "success", result.first[:status]
  end

  def test_execute_tool_not_found
    calls = { "call_1" => OpenStruct.new(name: "nonexistent", id: "call_1", arguments: {}) }
    result = @executor.execute(calls, @tools, hooks: @hooks, event_emitter: @emitter)
    assert_equal "error", result.first[:status]
  end

  def test_total_executions_tracked
    calls = { "call_1" => OpenStruct.new(name: "fake_tool", id: "call_1", arguments: {}) }
    @executor.execute(calls, @tools, hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, @executor.total_executions
  end
end

class FakeTool
  def name = "fake_tool"
  def description = "A fake tool"
  def parameters = {}
  def call(args, abort_controller: nil) = { result: "done", is_error: false }
  def params_schema = nil
  def provider_params = {}
end

class FakeEmitter
  def emit(event) = nil
end
