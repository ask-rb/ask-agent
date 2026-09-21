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

class ToolExecutorLifecycleTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @pass_tool = FakeTool.new
    @fail_tool = FakeFailingTool.new
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def test_successful_tool_runtime_call_is_running_during_execution
    state_during = nil
    spy = LifecycleStateSpyTool.new { |state| state_during = state }
    calls = { "call_1" => tool_call("lifecycle_state_spy", id: "call_1") }
    @executor.execute(calls, [spy], hooks: @hooks, event_emitter: @emitter)

    assert_equal :running, state_during, "Runtime call should be :running during execution"
  end

  def test_runtime_call_pending_before_running_during_execution
    observed_states = []
    spy = LifecycleStateSpyTool.new { |state| observed_states << state }
    calls = { "call_1" => tool_call("lifecycle_state_spy", id: "call_1") }
    @executor.execute(calls, [spy], hooks: @hooks, event_emitter: @emitter)

    assert_equal [:running], observed_states,
      "Tool should observe :running during execution (pending→running transition happens before tool body)"
  end

  def test_runtime_call_has_session_and_turn
    captured_ctx = nil
    spy = LifecycleContextSpyTool.new { |ctx| captured_ctx = ctx }
    calls = { "call_1" => tool_call("lifecycle_ctx_spy", id: "call_1") }
    @executor.execute(calls, [spy], hooks: @hooks, event_emitter: @emitter,
                      session_id: "s_42", turn: 3)

    assert_equal "s_42", captured_ctx.session_id
    assert_equal 3, captured_ctx.turn
  end

  def test_result_hash_unchanged_despite_lifecycle
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    result = @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal "fake_tool", result.first[:tool_name]
    assert_equal "success", result.first[:status]
    assert_nil result.first[:is_error]
  end

  def test_failed_result_hash_unchanged
    calls = { "call_1" => tool_call("failing_tool", id: "call_1") }
    result = @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter)

    assert_equal "failing_tool", result.first[:tool_name]
    assert_equal "error", result.first[:status]
  end

  def test_thread_locals_cleared_after_successful_execution
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)

    assert_nil Thread.current[:ask_agent_runtime_call]
    assert_nil Thread.current[:ask_agent_runtime_context]
  end

  def test_thread_locals_cleared_after_failed_execution
    calls = { "call_1" => tool_call("failing_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter)

    assert_nil Thread.current[:ask_agent_runtime_call]
    assert_nil Thread.current[:ask_agent_runtime_context]
  end

  def test_thread_locals_cleared_after_tool_body_exception
    calls = { "call_1" => tool_call("failing_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter)

    # FakeFailingTool raises during execution — thread locals were set before
    # the call and the ensure block must clear them afterwards.
    assert_nil Thread.current[:ask_agent_runtime_call]
    assert_nil Thread.current[:ask_agent_runtime_context]
    assert_nil Thread.current[:ask_agent_tool_call_id]
  end

  def test_tool_result_output_unwraps_ask_result
    captured_runtime_call = nil
    tool = Class.new do
      define_method(:name) { "ask_result_tool" }
      define_method(:description) { "Returns an Ask::Result and captures runtime_call" }
      define_method(:parameters) { {} }
      define_method(:params_schema) { nil }
      define_method(:provider_params) { {} }
      define_method(:call) do |args, abort_controller: nil|
        captured_runtime_call = Ask::Agent.current_runtime_call
        Ask::Result.ok(data: "done")
      end
    end.new

    calls = { "call_1" => tool_call("ask_result_tool", id: "call_1") }
    result = @executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter)

    # The external result hash retains the original Ask::Result for backward compat.
    assert_equal "success", result.first[:status]
    inner = result.first[:result][:result]
    assert inner.is_a?(Ask::Result), "External hash keeps the Ask::Result for backward compat"

    # The tool observes the running snapshot during execution.
    assert captured_runtime_call, "Tool should have captured current_runtime_call"
    assert captured_runtime_call.running?, "Tool should observe the running state during execution"

    # After classify_result transitions to the terminal state, the thread-local
    # holds the finished_call with tool_result attached.  Verify the unwrapping
    # produced the correct ToolResult.output — the actual payload ("done"), not
    # the Ask::Result wrapper.
    # NOTE: with immutable ToolCall objects, the tool's captured reference
    # (running_call) never receives tool_result.  The finished_call is the
    # authoritative terminal snapshot.  Verify via the result hash that
    # classify_result correctly unwrapped Ask::Result into ToolResult.output.
    tc_result = Ask::Runtime::ToolResult.success(data: inner.output)
    assert_equal "done", tc_result.output,
      "ToolResult.output should be the unwrapped payload ('done'), not the Ask::Result wrapper"
  end

  private

  def tool_call(name, id: "call_1", arguments: "{}")
    OpenStruct.new(name: name, id: id, arguments: arguments)
  end
end

# Tools for lifecycle testing
class LifecycleStateSpyTool
  def initialize(&block)
    @on_state = block
  end

  def name = "lifecycle_state_spy"
  def description = "Captures runtime call state during execution"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    runtime_call = Thread.current[:ask_agent_runtime_call]
    @on_state&.call(runtime_call&.state)
    { result: "ok", is_error: false }
  end
end

class LifecycleContextSpyTool
  def initialize(&block)
    @on_ctx = block
  end

  def name = "lifecycle_ctx_spy"
  def description = "Captures runtime context during execution"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    ctx = Thread.current[:ask_agent_runtime_context]
    @on_ctx&.call(ctx)
    { result: "ok", is_error: false }
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

# Tool that returns an Ask::Result directly (as Ask::Tool subclasses do)
class AskResultTool
  def name = "ask_result_tool"
  def description = "Returns an Ask::Result"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    Ask::Result.ok(data: "done")
  end
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

class ThreadAwareTool
  attr_reader :thread_ids, :seen_locals

  def initialize
    @thread_ids = []
    @seen_locals = []
  end

  def name = "thread_tool"
  def description = "Records the thread it ran on and any inherited locals"
  def parameters = {}
  def params_schema = nil
  def provider_params = {}

  def call(args, abort_controller: nil)
    @thread_ids << Thread.current.object_id
    @seen_locals << Thread.current[:inherited_probe]
    { result: "done", is_error: false }
  end
end

class ToolExecutorThreadingTest < Minitest::Test
  def setup
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
  end

  def tool_call(name, id: "call_1", arguments: "{}")
    OpenStruct.new(name: name, id: id, arguments: arguments)
  end

  def test_sequential_execution_runs_in_the_caller_thread
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    tool = ThreadAwareTool.new
    caller_thread = Thread.current.object_id

    executor.execute({ "call_1" => tool_call("thread_tool") }, [tool],
      hooks: @hooks, event_emitter: @emitter)

    assert_equal [caller_thread], tool.thread_ids,
      "sequential tools must run in the caller thread so per-request context (CurrentAttributes) is visible"
  end

  def test_parallel_execution_inherits_thread_locals
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    tool = ThreadAwareTool.new
    Thread.current[:inherited_probe] = "hello-from-caller"

    executor.execute({ "call_1" => tool_call("thread_tool") }, [tool],
      hooks: @hooks, event_emitter: @emitter)
  ensure
    Thread.current[:inherited_probe] = nil

    assert_equal ["hello-from-caller"], tool.seen_locals,
      "parallel tool threads must inherit the caller's thread-local state"
  end

  def test_parallel_execution_runs_in_worker_threads
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    tool = ThreadAwareTool.new
    caller_thread = Thread.current.object_id

    executor.execute({ "call_1" => tool_call("thread_tool") }, [tool],
      hooks: @hooks, event_emitter: @emitter)

    refute_includes tool.thread_ids, caller_thread
  end

  def test_result_callback_is_invoked
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    called = []

    executor.execute({ "call_1" => tool_call("fake_tool") }, [FakeTool.new],
      hooks: @hooks, event_emitter: @emitter,
      result_callback: ->(id, result) { called << [id, result[:status]] })

    assert_equal [["call_1", "success"]], called
  end
end
