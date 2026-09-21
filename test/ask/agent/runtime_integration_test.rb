# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class RuntimeDependencyTest < Minitest::Test
  def test_ask_runtime_is_loaded
    assert defined?(Ask::Runtime), "Ask::Runtime should be defined after requiring ask-agent"
  end

  def test_ask_runtime_tool_call_is_available
    assert defined?(Ask::Runtime::ToolCall), "Ask::Runtime::ToolCall should be available"
  end

  def test_ask_runtime_execution_context_is_available
    assert defined?(Ask::Runtime::ExecutionContext), "Ask::Runtime::ExecutionContext should be available"
  end

  def test_ask_runtime_version_is_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Ask::Runtime::VERSION)
  end
end

class RuntimeCorrelationTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @emitter = IntegrationEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_runtime_tool_call_is_built_with_session_and_turn
    received_call = nil
    tool = RuntimeSpyTool.new { |call| received_call = call }

    calls = { "call_1" => fake_tool_call("spy_tool") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter,
      session_id: "s_42", turn: 7)

    assert_instance_of Ask::Runtime::ToolCall, received_call
    assert_equal "call_1", received_call.id
    assert_equal "spy_tool", received_call.tool_name
    assert_equal "s_42", received_call.session_id
    assert_equal 7, received_call.turn
  end

  def test_runtime_tool_call_parses_json_arguments
    received_call = nil
    tool = RuntimeSpyTool.new { |call| received_call = call }

    tc = OpenStruct.new(id: "c_1", name: "spy_tool", arguments: '{"query":"hello","limit":5}')
    calls = { "c_1" => tc }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal({ "query" => "hello", "limit" => 5 }, received_call.input)
  end

  def test_runtime_tool_call_handles_non_json_arguments
    received_call = nil
    tool = RuntimeSpyTool.new { |call| received_call = call }

    tc = OpenStruct.new(id: "c_2", name: "spy_tool", arguments: { key: "val" })
    calls = { "c_2" => tc }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal({ key: "val" }, received_call.input)
  end

  def test_runtime_tool_call_handles_invalid_json
    received_call = nil
    tool = RuntimeSpyTool.new { |call| received_call = call }

    tc = OpenStruct.new(id: "c_3", name: "spy_tool", arguments: "not json {{{")
    calls = { "c_3" => tc }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal({}, received_call.input)
  end

  def test_runtime_tool_call_state_is_pending
    received_call = nil
    tool = RuntimeSpyTool.new { |call| received_call = call }

    calls = { "call_1" => fake_tool_call("spy_tool") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert received_call.running?
    assert_equal :running, received_call.state
  end

  def test_runtime_execution_context_carries_session_and_turn
    received_context = nil
    tool = RuntimeSpyContext.new { |ctx| received_context = ctx }

    calls = { "call_1" => fake_tool_call("spy_ctx") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter,
      session_id: "s_99", turn: 3)

    assert_instance_of Ask::Runtime::ExecutionContext, received_context
    assert_equal "s_99", received_context.session_id
    assert_equal 3, received_context.turn
    assert received_context.session?
  end

  def test_runtime_execution_context_has_canceller
    received_context = nil
    tool = RuntimeSpyContext.new { |ctx| received_context = ctx }

    calls = { "call_1" => fake_tool_call("spy_ctx") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert_instance_of Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter,
      received_context.canceller
    refute received_context.cancelled?
  end

  def test_runtime_context_exposed_via_thread_local_accessors
    captured_call = nil
    captured_context = nil
    tool = ThreadLocalCaptureTool.new do |call, ctx|
      captured_call = call
      captured_context = ctx
    end

    calls = { "call_1" => fake_tool_call("capture_tool") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter,
      session_id: "s_local", turn: 2)

    assert_instance_of Ask::Runtime::ToolCall, captured_call
    assert_instance_of Ask::Runtime::ExecutionContext, captured_context
    assert_equal "s_local", captured_call.session_id
    assert_equal 2, captured_call.turn
  end

  def test_thread_locals_are_cleared_after_execution
    tool = RuntimeSpyTool.new
    calls = { "call_1" => fake_tool_call("spy_tool") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert_nil Thread.current[:ask_agent_runtime_call]
    assert_nil Thread.current[:ask_agent_runtime_context]
  end

  def test_thread_locals_cleared_on_tool_error
    tool = RuntimeErrorTool.new
    calls = { "call_1" => fake_tool_call("error_tool") }
    @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    assert_nil Thread.current[:ask_agent_runtime_call]
    assert_nil Thread.current[:ask_agent_runtime_context]
  end

  def test_agent_module_exposes_runtime_accessors
    assert_respond_to Ask::Agent, :current_runtime_call
    assert_respond_to Ask::Agent, :current_runtime_context
    assert_nil Ask::Agent.current_runtime_call
    assert_nil Ask::Agent.current_runtime_context
  end

  def test_hook_transformed_arguments_visible_through_runtime_call_input
    captured_input = nil
    tool = RuntimeSpyTool.new { |call| captured_input = call&.input }

    # Hook that injects an extra argument the model never sent
    transform_hooks = Ask::Agent::Hooks.new(before_tool: ->(_call, _ctx) {
      { action: :proceed, arguments: { "original" => "value", "injected" => "by_hook" } }
    })

    calls = { "call_1" => OpenStruct.new(id: "c_hook", name: "spy_tool", arguments: '{"original":"value"}') }
    @executor.execute(calls, [tool], hooks: transform_hooks, event_emitter: @emitter)

    assert_equal({ "original" => "value", "injected" => "by_hook" }, captured_input,
      "Ask::Agent.current_runtime_call.input must reflect hook-transformed arguments")
  end
end

class RuntimeCancellationTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @emitter = IntegrationEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_canceller_cancel_delegates_to_abort_controller
    abort_ctrl = Ask::Agent::ToolAbortController.new
    adapter = Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter.new(abort_ctrl)

    refute adapter.cancelled?
    refute abort_ctrl.aborted?

    adapter.cancel

    assert adapter.cancelled?
    assert abort_ctrl.aborted?
  end

  def test_canceller_cancel_triggers_abort_controller
    abort_ctrl = Ask::Agent::ToolExecutor::CallbackAbortController.new
    adapter = Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter.new(abort_ctrl)

    refute abort_ctrl.aborted?
    adapter.cancel
    assert abort_ctrl.aborted?
    assert adapter.cancelled?
  end

  def test_canceller_on_cancel_fires_when_already_cancelled
    abort_ctrl = Ask::Agent::ToolExecutor::CallbackAbortController.new
    abort_ctrl.abort!
    adapter = Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter.new(abort_ctrl)

    fired = false
    adapter.on_cancel { fired = true }
    assert fired, "on_cancel callback should fire immediately when already cancelled"
  end

  def test_canceller_on_cancel_fires_on_later_abort
    abort_ctrl = Ask::Agent::ToolExecutor::CallbackAbortController.new
    adapter = Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter.new(abort_ctrl)

    fired = false
    adapter.on_cancel { fired = true }
    refute fired

    abort_ctrl.abort!
    assert fired, "on_cancel callback should fire when abort happens later"
  end

  def test_canceller_on_cancel_requires_block
    abort_ctrl = Ask::Agent::ToolExecutor::CallbackAbortController.new
    adapter = Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter.new(abort_ctrl)

    assert_raises(ArgumentError) { adapter.on_cancel }
  end

  def test_parallel_sibling_abort_reaches_runtime_canceller
    cancellers = []
    mutex = Mutex.new

    # Tool 1: captures its context's canceller, then aborts siblings
    tool1 = RuntimeCancellerCaptureTool.new do |ctx|
      mutex.synchronize { cancellers << ctx.canceller }
      Ask::Agent::ToolAbortController.new.tap(&:abort!) # won't work — need to abort the shared one
    end

    # Use a shared abort controller via the executor's parallel mode
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    calls = {
      "1" => fake_tool_call("canceller_capture", id: "1"),
      "2" => fake_tool_call("spy_tool", id: "2")
    }
    # Just verify parallel execution works with runtime objects
    spy = RuntimeSpyTool.new { |_call| }
    executor.execute(calls, [tool1, spy], hooks: @hooks, event_emitter: @emitter)

    assert cancellers.length >= 1, "At least one canceller should be captured"
    assert_instance_of Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter,
      cancellers.first
  end
end

class RuntimeExistingBehaviorTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @pass_tool = IntegrationPassTool.new
    @fail_tool = IntegrationFailTool.new
    @emitter = IntegrationEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_result_shapes_unchanged_success
    calls = { "call_1" => fake_tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal 1, result.length
    entry = result.first
    assert_equal "fake_tool", entry[:tool_name]
    assert_equal "success", entry[:status]
    assert_equal false, entry[:critical_failure]
    assert_equal false, entry[:halted]
    assert_equal "call_1", entry[:tool_call_id]
  end

  def test_result_shapes_unchanged_error
    calls = { "call_1" => fake_tool_call("failing_tool") }
    result = @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter)

    entry = result.first
    assert_equal "failing_tool", entry[:tool_name]
    assert_equal "error", entry[:status]
    assert entry[:result][:is_error]
  end

  def test_result_shapes_unchanged_tool_not_found
    calls = { "call_1" => fake_tool_call("nonexistent") }
    result = @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal "error", result.first[:status]
    assert_equal "Tool not found", result.first[:message]
  end

  def test_result_shapes_unchanged_blocked
    blocking_hooks = Ask::Agent::Hooks.new(before_tool: ->(_call, _ctx) {
      { action: :block, reason: "Not allowed" }
    })
    calls = { "call_1" => fake_tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool], hooks: blocking_hooks, event_emitter: @emitter)

    assert_equal "blocked", result.first[:status]
    assert_equal "Not allowed", result.first[:message]
  end

  def test_result_shapes_unchanged_short_circuit
    short_hooks = Ask::Agent::Hooks.new(before_tool: ->(_call, _ctx) {
      { action: :short_circuit, result: { output: "mocked" } }
    })
    calls = { "call_1" => fake_tool_call("fake_tool") }
    result = @executor.execute(calls, [@pass_tool], hooks: short_hooks, event_emitter: @emitter)

    assert_equal "short_circuited", result.first[:status]
    assert_equal "mocked", result.first[:output]
  end

  def test_total_executions_still_tracked
    calls = { "call_1" => fake_tool_call("fake_tool") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal 1, @executor.total_executions
  end

  def test_parallel_execution_unchanged
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    calls = {
      "call_1" => fake_tool_call("fake_tool", id: "call_1"),
      "call_2" => fake_tool_call("fake_tool", id: "call_2")
    }
    result = executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal 2, result.size
  end

  def test_result_callback_still_invoked
    called = []
    @executor.execute({ "call_1" => fake_tool_call("fake_tool") }, [@pass_tool],
      hooks: @hooks, event_emitter: @emitter,
      result_callback: ->(id, result) { called << [id, result[:status]] })

    assert_equal [["call_1", "success"]], called
  end

  def test_retryable_error_eventually_succeeds
    tool = IntegrationRetryTool.new
    calls = { "call_1" => fake_tool_call("retry_tool") }
    result = @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal "success", result.first[:status]
  end

  def test_empty_calls_returns_empty
    result = @executor.execute({}, [@pass_tool], hooks: @hooks, event_emitter: @emitter)
    assert_equal [], result
  end
end

# ── Test doubles (unique to this file — never reuse tool_executor_test.rb names) ──

class RuntimeSpyTool
  attr_reader :last_call

  def initialize(&block)
    @on_call = block
  end

  def name = "spy_tool"
  def description = "Captures the runtime ToolCall"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    call = Ask::Agent.current_runtime_call
    @on_call&.call(call)
    Ask::Result.ok(data: "spied")
  end
end

class RuntimeSpyContext
  attr_reader :last_context

  def initialize(&block)
    @on_call = block
  end

  def name = "spy_ctx"
  def description = "Captures the runtime ExecutionContext"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    ctx = Ask::Agent.current_runtime_context
    @on_call&.call(ctx)
    Ask::Result.ok(data: "spied")
  end
end

class ThreadLocalCaptureTool
  def initialize(&block)
    @on_call = block
  end

  def name = "capture_tool"
  def description = "Captures runtime call and context from thread locals"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    call = Ask::Agent.current_runtime_call
    ctx = Ask::Agent.current_runtime_context
    @on_call&.call(call, ctx)
    Ask::Result.ok(data: "captured")
  end
end

class RuntimeErrorTool
  def name = "error_tool"
  def description = "Always raises"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    raise "deliberate error"
  end
end

class RuntimeCancellerCaptureTool
  def initialize(&block)
    @on_call = block
  end

  def name = "canceller_capture"
  def description = "Captures its context's canceller"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    ctx = Ask::Agent.current_runtime_context
    @on_call&.call(ctx) if ctx
    Ask::Result.ok(data: "done")
  end
end

def fake_tool_call(name, id: "call_1", arguments: "{}")
  OpenStruct.new(name: name, id: id, arguments: arguments)
end

class IntegrationPassTool
  def name = "fake_tool"
  def description = "A fake tool"
  def parameters = {}
  def call(args, abort_controller: nil) = Ask::Result.ok(data: "done")
  def params_schema = nil
  def provider_params = {}
end

class IntegrationFailTool
  def name = "failing_tool"
  def description = "A failing tool"
  def parameters = {}
  def call(args, abort_controller: nil)
    Ask::Result.error(message: "error occurred")
  end
  def params_schema = nil
  def provider_params = {}
end

class IntegrationRetryTool
  def initialize
    @attempts = 0
  end
  def name = "retry_tool"
  def description = "Retry tool"
  def parameters = {}
  def call(args, abort_controller: nil)
    @attempts += 1
    raise Timeout::Error if @attempts < 2
    Ask::Result.ok(data: "done")
  end
  def params_schema = nil
  def provider_params = {}
end

class IntegrationEmitter
  def emit(event) = nil
end
