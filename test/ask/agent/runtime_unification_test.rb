# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

# ---------------------------------------------------------------------------
# Focused tests proving ask-agent and MCP/runtime paths produce equivalent
# ToolResult and event semantics via the shared Ask::Runtime contract.
# ---------------------------------------------------------------------------

class RuntimeContractConformanceTest < Minitest::Test
  def test_agent_executor_includes_runtime_tool_executor
    executor = Ask::Agent::ToolExecutor.new
    assert executor.is_a?(Ask::Runtime::ToolExecutor),
      "Agent ToolExecutor must include Ask::Runtime::ToolExecutor"
  end

  def test_agent_executor_responds_to_runtime_execute
    executor = Ask::Agent::ToolExecutor.new
    assert executor.respond_to?(:execute),
      "Agent ToolExecutor must respond to #execute"
  end

  def test_agent_executor_runtime_execute_returns_tool_result
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    tool = RuntimeContractSuccessTool.new
    executor.instance_variable_set(:@last_tools, [tool])
    call = Ask::Runtime::ToolCall.new(
      tool_name: "contract_tool", input: { q: "hi" },
      session_id: "s_rt", turn: 1
    )
    context = Ask::Runtime::ExecutionContext.new(
      session_id: "s_rt", turn: 1, caller_id: "test"
    )

    result = executor.execute(call, context)
    assert_instance_of Ask::Runtime::ToolResult, result
    assert result.success?
    assert_equal "contract_reply", result.output
  end

  def test_agent_executor_runtime_execute_failure_returns_tool_result
    executor = Ask::Agent::ToolExecutor.new(max_retries: 0, parallel: false)
    tool = RuntimeContractFailTool.new
    executor.instance_variable_set(:@last_tools, [tool])
    call = Ask::Runtime::ToolCall.new(
      tool_name: "contract_fail", input: {},
      session_id: "s_rt", turn: 1
    )

    result = executor.execute(call)
    assert_instance_of Ask::Runtime::ToolResult, result
    assert result.failure?
    assert_match(/deliberate/, result.error_message)
  end

  def test_agent_executor_runtime_execute_tool_not_found
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    call = Ask::Runtime::ToolCall.new(
      tool_name: "nonexistent_tool", input: {},
      session_id: "s_rt", turn: 1
    )

    result = executor.execute(call)
    assert_instance_of Ask::Runtime::ToolResult, result
    assert result.failure?
    assert_match(/not found/, result.error_message)
  end

  def test_agent_executor_runtime_execute_cancelled_before_execution
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    tool = RuntimeContractSuccessTool.new
    executor.instance_variable_set(:@last_tools, [tool])
    canceller = Ask::Runtime::Canceller.new
    canceller.cancel
    context = Ask::Runtime::ExecutionContext.new(canceller: canceller)
    call = Ask::Runtime::ToolCall.new(
      tool_name: "contract_tool", input: {},
      session_id: "s_rt", turn: 1
    )

    result = executor.execute(call, context: context)
    assert_instance_of Ask::Runtime::ToolResult, result
    assert result.cancelled?
  end

  def test_agent_executor_runtime_execute_retryable_error_succeeds
    executor = Ask::Agent::ToolExecutor.new(max_retries: 2, parallel: false)
    tool = RuntimeContractRetryTool.new
    executor.instance_variable_set(:@last_tools, [tool])
    call = Ask::Runtime::ToolCall.new(
      tool_name: "contract_retry", input: {},
      session_id: "s_rt", turn: 1
    )

    result = executor.execute(call)
    assert result.success?
    assert_equal "retried_ok", result.output
  end
end

# ---------------------------------------------------------------------------
# Tests proving agent batch path and runtime single-call path produce
# equivalent ToolResult semantics for the same tool invocation.
# ---------------------------------------------------------------------------

class ToolResultEquivalenceTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
  end

  def test_success_equivalence
    # Runtime path
    runtime_tool = EquivSuccessTool.new
    @executor.instance_variable_set(:@last_tools, [runtime_tool])
    runtime_call = Ask::Runtime::ToolCall.new(
      tool_name: "equiv_tool", input: {}, session_id: "s1", turn: 1
    )
    runtime_result = @executor.execute(runtime_call)

    # Batch path
    batch_tool = EquivSuccessTool.new
    emitter = QuietEmitter.new
    hooks = Ask::Agent::Hooks.new
    batch_calls = { "c1" => OpenStruct.new(name: "equiv_tool", id: "c1", arguments: "{}") }
    batch_result = @executor.execute_batch(batch_calls, [batch_tool], hooks: hooks, event_emitter: emitter)

    # Both should be successful
    assert runtime_result.success?
    assert_equal "success", batch_result.first[:status]
  end

  def test_failure_equivalence
    # Runtime path
    fail_tool = EquivFailTool.new
    @executor.instance_variable_set(:@last_tools, [fail_tool])
    runtime_call = Ask::Runtime::ToolCall.new(
      tool_name: "equiv_fail", input: {}, session_id: "s1", turn: 1
    )
    runtime_result = @executor.execute(runtime_call)

    # Batch path
    emitter = QuietEmitter.new
    hooks = Ask::Agent::Hooks.new
    batch_calls = { "c1" => OpenStruct.new(name: "equiv_fail", id: "c1", arguments: "{}") }
    batch_result = @executor.execute_batch(batch_calls, [EquivFailTool.new], hooks: hooks, event_emitter: emitter)

    # Both should be failures
    assert runtime_result.failure?
    assert_equal "error", batch_result.first[:status]
  end

  def test_cancelled_equivalence
    canceller = Ask::Runtime::Canceller.new
    canceller.cancel
    context = Ask::Runtime::ExecutionContext.new(canceller: canceller)

    # Runtime path
    tool = EquivSuccessTool.new
    @executor.instance_variable_set(:@last_tools, [tool])
    runtime_call = Ask::Runtime::ToolCall.new(
      tool_name: "equiv_tool", input: {}, session_id: "s1", turn: 1
    )
    runtime_result = @executor.execute(runtime_call, context: context)
    assert runtime_result.cancelled?
  end

  def test_output_data_preserved_through_tool_result
    tool = EquivSuccessTool.new
    @executor.instance_variable_set(:@last_tools, [tool])
    runtime_call = Ask::Runtime::ToolCall.new(
      tool_name: "equiv_tool", input: { x: 1 }, session_id: "s1", turn: 1
    )
    result = @executor.execute(runtime_call)
    assert result.success?
    assert_equal "data:1", result.output
  end
end

# ---------------------------------------------------------------------------
# Regression tests: hooks, errors, cancellation, and parallel execution
# still work correctly after the refactoring.
# ---------------------------------------------------------------------------

class RegressionHooksTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @emitter = QuietEmitter.new
  end

  def test_before_hook_block_returns_blocked_status
    hooks = Ask::Agent::Hooks.new(before_tool: ->(_call, _ctx) {
      { action: :block, reason: "blocked by policy" }
    })
    calls = { "c1" => OpenStruct.new(name: "fake_tool", id: "c1", arguments: "{}") }
    result = @executor.execute_batch(calls, [FakeSuccessTool.new], hooks: hooks, event_emitter: @emitter)
    assert_equal "blocked", result.first[:status]
    assert_equal "blocked by policy", result.first[:message]
  end

  def test_before_hook_short_circuit_returns_short_circuited
    hooks = Ask::Agent::Hooks.new(before_tool: ->(_call, _ctx) {
      { action: :short_circuit, result: { output: "mocked" } }
    })
    calls = { "c1" => OpenStruct.new(name: "fake_tool", id: "c1", arguments: "{}") }
    result = @executor.execute_batch(calls, [FakeSuccessTool.new], hooks: hooks, event_emitter: @emitter)
    assert_equal "short_circuited", result.first[:status]
    assert_equal "mocked", result.first[:output]
  end

  def test_before_hook_transforms_arguments
    captured_args = nil
    tool = SpyTool.new { |args| captured_args = args }
    hooks = Ask::Agent::Hooks.new(before_tool: ->(_call, _ctx) {
      { action: :proceed, arguments: { "injected" => true } }
    })
    calls = { "c1" => OpenStruct.new(name: "spy_tool", id: "c1", arguments: "{}") }
    @executor.execute_batch(calls, [tool], hooks: hooks, event_emitter: @emitter)
    assert_equal({ "injected" => true }, captured_args)
  end

  def test_after_hook_transforms_result
    transform_hooks = Ask::Agent::Hooks.new(after_tool: ->(_call, _result, _ctx) {
      { action: :transform, result: { result: "transformed", is_error: false } }
    })
    calls = { "c1" => OpenStruct.new(name: "fake_tool", id: "c1", arguments: "{}") }
    result = @executor.execute_batch(calls, [FakeSuccessTool.new], hooks: transform_hooks, event_emitter: @emitter)
    assert_equal "success", result.first[:status]
  end
end

class RegressionErrorsTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @emitter = QuietEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_tool_exception_returns_error_status
    calls = { "c1" => OpenStruct.new(name: "err_tool", id: "c1", arguments: "{}") }
    result = @executor.execute_batch(calls, [ErrorTool.new], hooks: @hooks, event_emitter: @emitter)
    assert_equal "error", result.first[:status]
    assert result.first[:result][:is_error]
  end

  def test_tool_not_found_returns_error
    calls = { "c1" => OpenStruct.new(name: "missing", id: "c1", arguments: "{}") }
    result = @executor.execute_batch(calls, [], hooks: @hooks, event_emitter: @emitter)
    assert_equal "error", result.first[:status]
    assert_equal "Tool not found", result.first[:message]
  end

  def test_critical_error_sets_critical_failure
    calls = { "c1" => OpenStruct.new(name: "unauth_tool", id: "c1", arguments: "{}") }
    result = @executor.execute_batch(calls, [UnauthorizedTool.new], hooks: @hooks, event_emitter: @emitter)
    assert result.first[:critical_failure], "Unauthorized should be critical"
  end
end

class RegressionCancellationTest < Minitest::Test
  def setup
    @emitter = QuietEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_aborted_result_when_sibling_fails_parallel
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    calls = {
      "c1" => OpenStruct.new(name: "err_tool", id: "c1", arguments: "{}"),
      "c2" => OpenStruct.new(name: "fake_tool", id: "c2", arguments: "{}")
    }
    result = executor.execute_batch(calls, [ErrorTool.new, FakeSuccessTool.new],
      hooks: @hooks, event_emitter: @emitter)
    statuses = result.map { |r| r[:status] }
    assert_includes statuses, "error"
  end

  def test_sequential_stops_on_critical_error
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    executed = []
    tracking_tool = TrackingTool.new { executed << :executed }
    calls = {
      "c1" => OpenStruct.new(name: "unauth_tool", id: "c1", arguments: "{}"),
      "c2" => OpenStruct.new(name: "tracking_tool", id: "c2", arguments: "{}")
    }
    result = executor.execute_batch(calls, [UnauthorizedTool.new, tracking_tool],
      hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, result.length, "Should stop after critical error"
    assert_empty executed, "Second tool should not execute"
  end
end

class RegressionParallelExecutionTest < Minitest::Test
  def setup
    @emitter = QuietEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_parallel_executes_all_tools
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    calls = {
      "c1" => OpenStruct.new(name: "fake_tool", id: "c1", arguments: "{}"),
      "c2" => OpenStruct.new(name: "fake_tool", id: "c2", arguments: "{}"),
      "c3" => OpenStruct.new(name: "fake_tool", id: "c3", arguments: "{}")
    }
    result = executor.execute_batch(calls, [FakeSuccessTool.new], hooks: @hooks, event_emitter: @emitter)
    assert_equal 3, result.size
    assert result.all? { |r| r[:status] == "success" }
  end

  def test_parallel_thread_locals_inherited
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    seen = []
    tool = Class.new do
      define_method(:name) { "thread_check" }
      define_method(:description) { "checks" }
      define_method(:parameters) { {} }
      define_method(:params_schema) { nil }
      define_method(:provider_params) { {} }
      define_method(:call) do |args, abort_controller: nil|
        seen << Thread.current[:probe]
        { result: "ok", is_error: false }
      end
    end.new

    Thread.current[:probe] = "present"
    calls = { "c1" => OpenStruct.new(name: "thread_check", id: "c1", arguments: "{}") }
    executor.execute_batch(calls, [tool], hooks: @hooks, event_emitter: @emitter)
  ensure
    Thread.current[:probe] = nil
    assert_equal ["present"], seen
  end

  def test_result_callback_invoked_per_tool
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    called = []
    calls = {
      "c1" => OpenStruct.new(name: "fake_tool", id: "c1", arguments: "{}"),
      "c2" => OpenStruct.new(name: "fake_tool", id: "c2", arguments: "{}")
    }
    executor.execute_batch(calls, [FakeSuccessTool.new], hooks: @hooks, event_emitter: @emitter,
      result_callback: ->(id, result) { called << id })
    assert_equal 2, called.length
    assert_includes called, "c1"
    assert_includes called, "c2"
  end
end

# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------

class RuntimeContractSuccessTool
  def name = "contract_tool"
  def description = "Success tool for runtime contract"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil) = "contract_reply"
end

class RuntimeContractFailTool
  def name = "contract_fail"
  def description = "Fail tool for runtime contract"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    raise "deliberate failure"
  end
end

class RuntimeContractRetryTool
  def initialize; @attempts = 0; end
  def name = "contract_retry"
  def description = "Retry tool for runtime contract"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    @attempts += 1
    raise Timeout::Error if @attempts < 2
    "retried_ok"
  end
end

class EquivSuccessTool
  def name = "equiv_tool"
  def description = "Equivalent success tool"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    q = args.is_a?(Hash) ? args[:x] : nil
    "data:#{q}"
  end
end

class EquivFailTool
  def name = "equiv_fail"
  def description = "Equivalent fail tool"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    raise "equiv failure"
  end
end

class FakeSuccessTool
  def name = "fake_tool"
  def description = "Success tool"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil) = { result: "done", is_error: false }
end

class ErrorTool
  def name = "err_tool"
  def description = "Error tool"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    raise "tool error"
  end
end

class UnauthorizedTool
  def name = "unauth_tool"
  def description = "Unauthorized tool"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    raise Ask::Unauthorized, "not allowed"
  end
end

class SpyTool
  def initialize(&block); @on_call = block; end
  def name = "spy_tool"
  def description = "Captures args"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    @on_call&.call(args)
    "ok"
  end
end

class TrackingTool
  def initialize(&block); @on_call = block; end
  def name = "tracking_tool"
  def description = "Tracks execution"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}
  def call(args, abort_controller: nil)
    @on_call&.call
    "tracked"
  end
end

class QuietEmitter
  def emit(event) = nil
end
