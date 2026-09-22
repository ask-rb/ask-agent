# frozen_string_literal: true

require_relative "../../test_helper"
require "ask/session"
require "tmpdir"

PROVIDER_AVAILABLE =
  begin
    require "ask-state-providers"
    true
  rescue LoadError
    begin
      require "ask/state"
      require "ask/state/providers/sqlite"
      true
    rescue LoadError
      false
    end
  end

class SessionAdapterTest < Minitest::Test
  Events = Ask::Agent::Events

  # Minimal chat double matching the Chat methods SessionAdapter touches.
  class FakeChat
    attr_reader :messages

    def initialize
      @messages = []
    end

    def reset_messages!
      @messages.clear
    end

    def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil, attachments: nil)
      @messages << Ask::Message.new(
        role: role,
        content: content,
        tool_call_id: tool_call_id,
        tool_calls: tool_calls
      )
    end
  end

  # Fake agent exposing the Ask::Agent::Session surface the adapter uses.
  class FakeAgent
    attr_reader :id, :chat, :messages, :turn_count

    def initialize(id: "fake-agent", response: "ok", error: nil, &on_run)
      @id = id
      @response = response
      @error = error
      @on_run = on_run
      @handlers = []
      @chat = FakeChat.new
      @messages = []
      @turn_count = 0
      @aborted = false
    end

    def on_event(&block)
      @handlers << block
      self
    end

    def emit(event)
      @handlers.each { |h| h.call(event) }
    end

    def run(message, **)
      @on_run&.call(self, message)
      raise @error if @error

      @messages += [
        Ask::Message.new(role: :user, content: message.to_s),
        Ask::Message.new(role: :assistant, content: @response)
      ]
      @turn_count += 1
      @response
    end

    def abort
      @aborted = true
    end

    def abort_requested?
      @aborted
    end
  end

  def setup
    @host = Ask::Session::Host.new(store: Ask::Session::Store.new)
  end

  def events_for(session_id)
    @host.events(session_id)
  end

  def types_for(session_id)
    events_for(session_id).map(&:type)
  end

  # --- create ---

  def test_create_creates_and_binds_host_session
    agent = FakeAgent.new(id: "agent-abc")

    adapter = Ask::Agent::SessionAdapter.create(agent: agent, host: @host)

    assert_equal "agent-abc", adapter.session_id
    assert_equal agent, adapter.agent
    assert_equal @host, adapter.host

    record = @host.session("agent-abc")
    assert_equal "agent-abc", record.id
    assert_equal :active, record.status
    assert_includes types_for("agent-abc"), "session.created"
  end

  # --- run ---

  def test_run_records_user_message_and_snapshot
    agent = FakeAgent.new(id: "run-1")
    adapter = Ask::Agent::SessionAdapter.create(agent: agent, host: @host)

    result = adapter.run("hello there")

    assert_equal "ok", result

    types = types_for("run-1")
    assert_includes types, "message.added"
    assert_includes types, "agent.snapshot"

    message_event = events_for("run-1").find { |e| e.type == "message.added" }
    assert_equal "hello there", message_event.payload[:content]

    snapshot = events_for("run-1").find { |e| e.type == "agent.snapshot" }
    assert_kind_of Array, snapshot.payload[:messages]
    assert_equal agent.messages.size, snapshot.payload[:messages].size
    assert_equal agent.turn_count, snapshot.payload[:turn_count]
    assert_equal :user, snapshot.payload[:messages].first[:role]
    assert_equal "hello there", snapshot.payload[:messages].first[:content]
  end

  # --- event mapping ---

  def test_agent_events_map_to_session_events
    agent = FakeAgent.new(id: "map-1") do |a|
      a.emit(Events::TurnStart.new)
      a.emit(Events::TextDelta.new(content: "Hi"))
      a.emit(Events::ThinkingDelta.new(content: "hmm"))
      a.emit(Events::ToolExecutionStart.new(name: "search", arguments: '{"q":"x"}', id: "call_1"))
      a.emit(Events::ToolExecutionUpdate.new(name: "search", id: "call_1", partial_result: "pa"))
      a.emit(Events::ToolExecutionEnd.new(
        name: "search", id: "call_1", result: "done", is_error: false, duration_ms: 5
      ))
      a.emit(Events::TodoUpdated.new(todos: [{ content: "step", status: "pending" }]))
      a.emit(Events::PlanProposed.new(plan: "do the thing"))
      a.emit(Events::PlanApproved.new(plan: "do the thing"))
      a.emit(Events::PlanRejected.new(plan: "do the thing"))
      a.emit(Events::Error.new(error: "boom", recoverable: true))
    end
    adapter = Ask::Agent::SessionAdapter.create(agent: agent, host: @host)

    adapter.run("go")

    types = types_for("map-1")
    %w[
      turn.started model.streaming model.thinking
      tool.use tool.delta tool.result
      todos.updated plan.proposed plan.approved plan.rejected
      error
    ].each do |type|
      assert_includes types, type, "expected session event #{type.inspect}"
    end

    turn = events_for("map-1").find { |e| e.type == "turn.started" }
    assert_equal 1, turn.payload[:turn_id]
    # Turn id is scoped to the run and cleared in ensure.
    assert_nil adapter.current_turn_id

    tool_start = events_for("map-1").find { |e| e.type == "tool.use" }
    assert_equal "search", tool_start.payload[:tool_name]
    assert_equal "call_1", tool_start.payload[:tool_call_id]

    error_event = events_for("map-1").find { |e| e.type == "error" }
    assert_equal "boom", error_event.payload[:message]
    assert_equal true, error_event.payload[:recoverable]
  end

  # --- trace / causation ---

  def test_trace_id_and_causation_id_propagate
    agent = FakeAgent.new(id: "trace-1")
    adapter = Ask::Agent::SessionAdapter.create(agent: agent, host: @host)

    adapter.run("hi", trace_id: "trace-abc", causation_id: "cause-xyz")

    assert_equal "trace-abc", adapter.current_trace_id

    events_for("trace-1").each do |event|
      next if event.type == "session.created"

      assert_equal "trace-abc", event.trace_id, "#{event.type} should carry trace_id"
      assert_equal "cause-xyz", event.causation_id, "#{event.type} should carry causation_id"
    end
  end

  def test_trace_id_defaults_to_generated_value
    agent = FakeAgent.new(id: "trace-2")
    adapter = Ask::Agent::SessionAdapter.create(agent: agent, host: @host)

    adapter.run("hi")

    assert_match(/\Atrace_[0-9a-f]{16}\z/, adapter.current_trace_id)
    message_event = events_for("trace-2").find { |e| e.type == "message.added" }
    assert_equal adapter.current_trace_id, message_event.trace_id
    # Contract: the input message is the causal root (its causation_id is
    # nil when none was supplied); later events link back to its trace_id.
    snapshot = events_for("trace-2").find { |e| e.type == "agent.snapshot" }
    assert_equal message_event.trace_id, snapshot.causation_id
  end

  # --- resume ---

  def test_resume_missing_session_raises_adapter_error
    agent = FakeAgent.new

    error = assert_raises(Ask::Agent::SessionAdapter::Error) do
      Ask::Agent::SessionAdapter.resume(agent: agent, host: @host, session_id: "no-such-session")
    end

    assert_match(/no-such-session/, error.message)
    assert_match(/not found/i, error.message)
  end

  def test_resume_missing_snapshot_raises_adapter_error
    @host.create(id: "no-snap")
    agent = FakeAgent.new

    error = assert_raises(Ask::Agent::SessionAdapter::Error) do
      Ask::Agent::SessionAdapter.resume(agent: agent, host: @host, session_id: "no-snap")
    end

    assert_match(/snapshot/i, error.message)
    assert_match(/no-snap/, error.message)
  end

  def test_resume_restores_snapshot_into_agent
    original = FakeAgent.new(id: "resume-1")
    adapter = Ask::Agent::SessionAdapter.create(agent: original, host: @host)
    adapter.run("first message")

    restored_agent = FakeAgent.new(id: "resume-1")
    restored = Ask::Agent::SessionAdapter.resume(
      agent: restored_agent, host: @host, session_id: "resume-1"
    )

    assert_equal "resume-1", restored.session_id
    assert_equal restored_agent, restored.agent

    contents = restored_agent.chat.messages.map { |m| [m.role, m.content] }
    assert_includes contents, [:user, "first message"]
    assert_includes contents, [:assistant, "ok"]
    assert_equal original.turn_count, restored_agent.turn_count
    assert_equal restored_agent.chat.messages.size, restored_agent.messages.size
    refute_empty restored_agent.messages
  end

  # --- restart resume over durable ProviderStore/SQLite ---

  def test_restart_resume_restores_messages_and_turn_count
    skip "ask-state-providers is not available" unless PROVIDER_AVAILABLE && defined?(Ask::State::Providers::SQLite)

    Dir.mktmpdir("ask-agent-restart") do |dir|
      db_path = File.join(dir, "sessions.db")

      adapter1 = Ask::State::Providers::SQLite.new(path: db_path)
      store1 = Ask::Session::ProviderStore.new(adapter: adapter1)
      host1 = Ask::Session::Host.new(store: store1)

      original = FakeAgent.new(id: "restart-1")
      first = Ask::Agent::SessionAdapter.create(agent: original, host: host1)
      first.run("persist me")
      assert_equal 1, original.turn_count
      adapter1.close

      adapter2 = Ask::State::Providers::SQLite.new(path: db_path)
      store2 = Ask::Session::ProviderStore.new(adapter: adapter2)
      host2 = Ask::Session::Host.new(store: store2)

      record = host2.session("restart-1")
      assert_equal "restart-1", record.id
      assert_equal :active, record.status

      snapshot_event = host2.events("restart-1").reverse_each.find { |e| e.type == "agent.snapshot" }
      refute_nil snapshot_event
      assert_kind_of Array, snapshot_event.payload[:messages]
      assert_equal 1, snapshot_event.payload[:turn_count]
      assert_equal :user, snapshot_event.payload[:messages].first[:role]
      assert_equal "persist me", snapshot_event.payload[:messages].first[:content]

      restored_agent = FakeAgent.new(id: "restart-1")
      restored = Ask::Agent::SessionAdapter.resume(
        agent: restored_agent, host: host2, session_id: "restart-1"
      )

      contents = restored_agent.chat.messages.map { |m| [m.role, m.content] }
      assert_includes contents, [:user, "persist me"]
      assert_includes contents, [:assistant, "ok"]
      assert_equal original.turn_count, restored_agent.turn_count
      assert_equal 1, restored_agent.turn_count
      assert_equal restored_agent.chat.messages.size, restored_agent.messages.size
      refute_empty restored_agent.messages

      result = restored.run("follow up after restart")
      assert_equal "ok", result
      assert_equal 2, restored_agent.turn_count
      assert_includes host2.events("restart-1").map(&:type), "agent.snapshot"

      adapter2.close
    end
  end

  # --- failed run ---

  def test_failed_run_records_turn_failed_and_reraises
    agent = FakeAgent.new(id: "fail-1", error: RuntimeError.new("kaput")) do |a|
      a.emit(Events::TurnStart.new)
    end
    adapter = Ask::Agent::SessionAdapter.create(agent: agent, host: @host)

    error = assert_raises(RuntimeError) { adapter.run("go") }
    assert_equal "kaput", error.message

    types = types_for("fail-1")
    assert_includes types, "turn.failed"
    refute_includes types, "agent.snapshot"

    failed = events_for("fail-1").find { |e| e.type == "turn.failed" }
    assert_equal "kaput", failed.payload[:error]
    assert_equal "RuntimeError", failed.payload[:error_class]
    refute_nil failed.trace_id
  end
end
