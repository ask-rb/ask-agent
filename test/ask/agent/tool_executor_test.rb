# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class ToolExecutorTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @pass_tool = FakeTool.new
    @fail_tool = FakeFailingTool.new
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_execute_empty_calls_returns_empty
    result = @executor.execute({}, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal [], result
  end

  def test_execute_tool_call_success
    calls = { "call_1" => tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, result.length
    assert_equal "success", result.first[:status]
  end

  def test_execute_tool_not_found
    calls = { "call_1" => tool_call("nonexistent") }
    result = @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal "error", result.first[:status]
  end

  def test_total_executions_tracked
    calls = { "call_1" => tool_call("fake_tool") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, @executor.total_executions
  end

  def test_tool_error_captured
    calls = { "call_1" => tool_call("failing_tool") }
    result = @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal "error", result.first[:status]
  end

  def test_before_hook_can_block
    blocking_hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :block, reason: "Not allowed" }
    })
    calls = { "call_1" => tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool], hooks: blocking_hooks, event_emitter: @emitter)
    assert_equal "blocked", result.first[:status]
  end

  def test_before_hook_can_short_circuit
    short_hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :short_circuit, result: { output: "mocked" } }
    })
    calls = { "call_1" => tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool], hooks: short_hooks, event_emitter: @emitter)
    assert_equal "short_circuited", result.first[:status]
  end

  def test_retryable_error_eventually_succeeds
    tool = FakeRetryTool.new
    calls = { "call_1" => tool_call("retry_tool") }
    result = @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal "success", result.first[:status]
  end

  def test_parallel_execution
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    calls = {
      "call_1" => tool_call("fake_tool", id: "call_1"),
      "call_2" => tool_call("fake_tool", id: "call_2")
    }
    result = executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal 2, result.size
  end

  def test_aborted_when_tool_raises
    calls = { "call_1" => tool_call("failing_tool") }
    result = @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal "error", result.first[:status]
  end

  private

  def tool_call(name, id: "call_1", arguments: "{}")
    OpenStruct.new(name: name, id: id, arguments: arguments)
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

class FakeFailingTool
  def name = "failing_tool"
  def description = "A failing tool"
  def parameters = {}
  def call(args, abort_controller: nil)
    raise "error occurred"
  end
  def params_schema = nil
  def provider_params = {}
end

class FakeRetryTool
  def initialize
    @attempts = 0
  end
  def name = "retry_tool"
  def description = "Retry tool"
  def parameters = {}
  def call(args, abort_controller: nil)
    @attempts += 1
    raise Timeout::Error if @attempts < 2
    { result: "done", is_error: false }
  end
  def params_schema = nil
  def provider_params = {}
end

class FakeEmitter
  def emit(event) = nil
end

# ── Halted tool support ──

class FakeHaltTool
  def name = "halt_tool"
  def description = "A tool that halts"
  def parameters = {}
  def call(args, abort_controller: nil)
    Ask::Result.ok(data: "halted", metadata: { halted: true })
  end
  def params_schema = nil
  def provider_params = {}
end

class ToolExecutorHaltTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @halt_tool = FakeHaltTool.new
    @pass_tool = FakeTool.new
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_halted_tool_stops_sequential_execution
    calls = { "1" => tool_call("halt_tool"), "2" => tool_call("fake_tool") }
    result = @executor.execute(calls, [@halt_tool, @pass_tool],
      hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, result.length, "Only halted tool should execute"
    assert result.first[:halted], "Halted flag should be set"
  end

  def test_non_halted_tool_does_not_set_halted
    calls = { "1" => tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool],
      hooks: @hooks, event_emitter: @emitter)
    assert result.first[:halted] != true, "Normal tool should not set halted"
  end

  def test_halted_tool_aborts_siblings_in_parallel
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    calls = {
      "1" => tool_call("halt_tool", id: "1"),
      "2" => tool_call("fake_tool", id: "2")
    }
    result = executor.execute(calls, [@halt_tool, @pass_tool],
      hooks: @hooks, event_emitter: @emitter)
    refute_empty result, "Should have results"
  end

  def test_raise_halt_sets_halted_metadata
    tool = Class.new(Ask::Tool) do
      description "Halt tool"
      def execute
        raise Ask::Tool::Halt.new("stopped here")
      end
    end
    result = tool.new.call({})
    assert result.ok?
    assert result.metadata[:halted], "Halt exception should set halted metadata"
  end

  private

  def tool_call(name, id: "call_1", arguments: "{}")
    OpenStruct.new(name: name, id: id, arguments: arguments)
  end
end
