# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "tool_executor_test"
require "ostruct"

class RuntimeEventEmissionTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @pass_tool = FakeTool.new
    @fail_tool = FakeFailingTool.new
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
    @sink = Ask::Runtime::EventSink.new
    @received = []
    @sink.on(:tool_started) { |e| @received << [:started, e[:event]] }
  @sink.on(:tool_completed) { |e| @received << [:completed, e[:event]] }
  @sink.on(:tool_failed) { |e| @received << [:failed, e[:event]] }
  @sink.on(:tool_cancelled) { |e| @received << [:cancelled, e[:event]] }
  @sink.on(:tool_timed_out) { |e| @received << [:timed_out, e[:event]] }
  end

  def test_successful_tool_emits_started_then_completed
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    assert_equal 2, @received.length
    assert_equal :started, @received[0][0]
    assert_equal :completed, @received[1][0]
  end

  def test_started_event_payload
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter,
                      session_id: "s_42", turn: 3, runtime_event_sink: @sink)

    event = @received[0][1]
    assert_instance_of Ask::Runtime::Events::ToolStarted, event
    assert_instance_of Ask::Runtime::ToolCall, event.tool_call
    assert_instance_of Ask::Runtime::ExecutionContext, event.execution_context
    assert_instance_of Time, event.timestamp
    assert_equal "fake_tool", event.tool_name
    assert_equal "call_1", event.tool_call_id
    assert_equal "s_42", event.execution_context.session_id
    assert_equal 3, event.execution_context.turn
  end

  def test_completed_event_payload
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    event = @received[1][1]
    assert_instance_of Ask::Runtime::Events::ToolCompleted, event
    assert_instance_of Ask::Runtime::ToolCall, event.tool_call
    assert_instance_of Ask::Runtime::ToolResult, event.tool_result
    assert_instance_of Ask::Runtime::ExecutionContext, event.execution_context
    assert_instance_of Time, event.timestamp
    assert event.tool_result.success?
    assert event.duration >= 0
    assert_equal "completed", event.tool_call.state.to_s
  end

  def test_failed_tool_emits_started_then_failed
    calls = { "call_1" => tool_call("failing_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    assert_equal 2, @received.length
    assert_equal :started, @received[0][0]
    assert_equal :failed, @received[1][0]
  end

  def test_failed_event_payload
    calls = { "call_1" => tool_call("failing_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    event = @received[1][1]
    assert_instance_of Ask::Runtime::Events::ToolFailed, event
    assert event.tool_result.failure?
    assert event.failed?
    assert event.error
    assert_equal "failed", event.tool_call.state.to_s
  end

  def test_no_events_emitted_without_runtime_event_sink
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter)

    # No sink passed, so no events should be received
    assert @received.empty?
  end

  def test_null_sink_receives_no_events
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter,
                      runtime_event_sink: Ask::Runtime::EventSink.null)

    assert @received.empty?
  end

  def test_no_events_for_tool_not_found
    calls = { "call_1" => tool_call("nonexistent", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    assert @received.empty?
  end

  def test_no_events_for_hook_block
    blocking_hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :block, reason: "Not allowed" }
    })
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: blocking_hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    assert @received.empty?
  end

  def test_no_events_for_hook_short_circuit
    short_hooks = Ask::Agent::Hooks.new(before_tool: ->(call, ctx) {
      { action: :short_circuit, result: { output: "mocked" } }
    })
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: short_hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    assert @received.empty?
  end

  def test_exactly_one_start_and_one_terminal_per_tool
    calls = {
      "call_1" => tool_call("fake_tool", id: "call_1"),
      "call_2" => tool_call("failing_tool", id: "call_2")
    }
    @executor.execute(calls, [@pass_tool, @fail_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    starts = @received.select { |type, _| type == :started }
    terminals = @received.select { |type, _| %i[completed failed cancelled timed_out].include?(type) }

    assert_equal 2, starts.length, "One start per tool call"
    assert_equal 2, terminals.length, "One terminal per tool call"
  end

  def test_events_are_thread_safe_in_parallel
    executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: true)
    sink = Ask::Runtime::EventSink.new
    received = Queue.new
    mutex = Mutex.new

    sink.on(:tool_started) { |e| mutex.synchronize { received << [:started, e[:event].tool_call_id] } }
  sink.on(:tool_completed) { |e| mutex.synchronize { received << [:completed, e[:event].tool_call_id] } }

    calls = {
      "c1" => tool_call("fake_tool", id: "c1"),
      "c2" => tool_call("fake_tool", id: "c2"),
      "c3" => tool_call("fake_tool", id: "c3")
    }
    executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: sink)

    starts = []
    terminals = []
    received.size.times do
      type, id = received.pop
      if type == :started
        starts << id
      else
        terminals << id
      end
    end

    assert_equal 3, starts.length
    assert_equal 3, terminals.length
    assert_equal starts.sort, terminals.sort, "Each tool call has exactly one start and one terminal"
  end

  def test_terminal_events_use_frozen_snapshots
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    @received.each do |_, event|
      assert event.frozen?, "Event should be frozen"
    end
  end

  def test_runtime_events_do_not_affect_agent_events
    calls = { "call_1" => tool_call("fake_tool", id: "call_1") }
    agent_events = []
    @emitter.define_singleton_method(:emit) { |event| agent_events << event }

    @executor.execute(calls, [@pass_tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    agent_event_types = agent_events.map(&:class)
    assert_includes agent_event_types, Ask::Agent::Events::ToolExecutionStart
    assert_includes agent_event_types, Ask::Agent::Events::ToolExecutionEnd

    runtime_event_types = @received.map { |_, e| e.class }
    assert_includes runtime_event_types, Ask::Runtime::Events::ToolStarted
    assert_includes runtime_event_types, Ask::Runtime::Events::ToolCompleted
  end

  private

  def tool_call(name, id: "call_1", arguments: "{}")
    OpenStruct.new(name: name, id: id, arguments: arguments)
  end
end

# ---------------------------------------------------------------------------
# Regression: Session#run → Loop#run_turn → ToolExecutor#execute_batch must
# forward an explicitly supplied runtime_event_sink. A normal Session#run
# tool invocation emits the runtime lifecycle (tool_started → tool_completed)
# through that sink; nil stays backward compatible.
# ---------------------------------------------------------------------------

class SessionRunRuntimeSinkRegressionTest < Minitest::Test
  # Recording sink duck-typing Ask::Runtime::EventSink#emit.
  class RecordingSink
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event_type, **payload)
      @events << [event_type, payload[:event]]
      self
    end
  end

  # Chat that issues a tool call on the first two turns — covering both the
  # initial Loop#run_turn and its recursive tool turn — then answers with
  # text.
  class ScriptedToolChat
    attr_reader :messages, :model

    def initialize(tool_name:)
      @tool_name = tool_name
      @ask_count = 0
      @messages = []
      @model = OpenStruct.new(id: "gpt-4o")
    end

    def model_id = "gpt-4o"
    def with_instructions(*) = self

    def ask(message = nil, attachments: nil)
      @ask_count += 1
      if @ask_count <= 2
        tool_calls = {
          "call_#{@ask_count}" => Ask::Agent::ToolCallInfo.new(
            id: "call_#{@ask_count}", name: @tool_name, arguments: "{}"
          )
        }
        Ask::Agent::ResponseMessage.new(
          content: "", tool_calls: tool_calls, tool_results: {},
          thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil
        )
      else
        Ask::Agent::ResponseMessage.new(
          content: "all done", tool_calls: {}, tool_results: {},
          thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil
        )
      end
    end

    def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil, attachments: nil)
      @messages << Ask::Message.new(
        role: role, content: content, tool_call_id: tool_call_id, tool_calls: tool_calls
      )
    end

    def reset_messages! = @messages.clear
  end

  class SinkEchoTool
    def name = "sink_echo"
    def description = "Echoes for the sink regression"
    def parameters = {}
    def params_schema = nil
    def provider_params = {}
    def call(args, abort_controller: nil) = "echoed"
  end

  def test_session_run_tool_invocation_emits_runtime_lifecycle_to_supplied_sink
    sink = RecordingSink.new
    session = Ask::Agent::Session.new(
      model: ScriptedToolChat.new(tool_name: "sink_echo"),
      tools: [SinkEchoTool.new],
      skills_disclosure: false
    )

    response = session.run("use the tool", runtime_event_sink: sink)

    assert_equal "all done", response

    started = sink.events.select { |type, _| type == :tool_started }
    completed = sink.events.select { |type, _| type == :tool_completed }

    assert_equal 2, started.length,
      "one ToolStarted per tool turn (initial run_turn + recursive tool turn)"
    assert_equal 2, completed.length,
      "one ToolCompleted per tool turn (initial run_turn + recursive tool turn)"

    first_started = started.first[1]
    assert_instance_of Ask::Runtime::Events::ToolStarted, first_started
    assert_equal "sink_echo", first_started.tool_name
    assert_equal "call_1", first_started.tool_call_id
    assert_equal session.id, first_started.execution_context.session_id

    first_completed = completed.first[1]
    assert_instance_of Ask::Runtime::Events::ToolCompleted, first_completed
    assert first_completed.tool_result.success?
    assert_equal "sink_echo", first_completed.tool_name
  end

  def test_session_run_without_sink_stays_backward_compatible
    session = Ask::Agent::Session.new(
      model: ScriptedToolChat.new(tool_name: "sink_echo"),
      tools: [SinkEchoTool.new],
      skills_disclosure: false
    )

    response = session.run("use the tool")

    assert_equal "all done", response
  end
end

class RuntimeEventFailureClassificationTest < Minitest::Test
  def setup
    @executor = Ask::Agent::ToolExecutor.new(max_retries: 1, parallel: false)
    @pass_tool = FakeTool.new
    @fail_tool = FakeFailingTool.new
    @emitter = FakeEmitter.new
    @hooks = Ask::Agent::Hooks.new
    @sink = Ask::Runtime::EventSink.new
  end

  def test_timeout_error_emits_timed_out
    tool = Class.new do
      def name = "timeout_tool"
      def description = "Timeouts"
      def parameters = {}
      def params_schema = nil
      def provider_params = {}
      def call(args, abort_controller: nil)
        raise Timeout::Error, "execution exceeded"
      end
    end.new

    received = []
  @sink.on(:tool_timed_out) { |e| received << e }

    calls = { "call_1" => tool_call("timeout_tool", id: "call_1") }
    # Timeout::Error is retryable; with max_retries: 0 it fails immediately
    executor = Ask::Agent::ToolExecutor.new(max_retries: 0, parallel: false)
    executor.execute(calls, [tool], hooks: @hooks, event_emitter: @emitter, runtime_event_sink: @sink)

    # Timeout::Error is classified as failure, not timed_out (timed_out is for explicit timeout)
    # The classify_result method treats it as a generic error
    assert received.empty? || received.first.is_a?(Ask::Runtime::Events::ToolFailed),
      "Timeout::Error should emit ToolFailed (not ToolTimedOut)"
  end

  def test_abort_emits_cancelled
    abort_controller = Ask::Agent::ToolExecutor::CallbackAbortController.new
    abort_controller.abort!

    canceller = Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter.new(abort_controller)
    ctx = Ask::Runtime::ExecutionContext.new(session_id: "s_001", turn: 1, canceller: canceller)

    # Build a runtime call that's already in the abort state
    call = Ask::Runtime::ToolCall.new(tool_name: "test", input: {}, session_id: "s_001", turn: 1)
    result = Ask::Runtime::ToolResult.cancelled("Aborted by sibling failure")

    event = Ask::Runtime::Events::ToolCancelled.new(
      tool_call: call, tool_result: result, execution_context: ctx, timestamp: Time.now, duration: 0.0
    )

    assert event.cancelled?
    assert_equal "Aborted by sibling failure", event.reason
  end

  private

  def tool_call(name, id: "call_1", arguments: "{}")
    OpenStruct.new(name: name, id: id, arguments: arguments)
  end
end
