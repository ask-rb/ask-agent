# frozen_string_literal: true

require_relative "../../test_helper"
require "ask/session"

unless String.method_defined?(:constantize)
  class String
    def constantize
      split("::").reject(&:empty?).inject(Object) { |obj, const| obj.const_get(const) }
    end
  end
end

module Ask
  module Agent
    class ApprovalPersistenceTest < Minitest::Test
      class CountingTool < Ask::Tool
        description "Counting tool"
        approval_required true
        param :value, type: :string, desc: "value", required: false

        def name = "counting_tool"

        class << self
          def calls = @calls ||= []
          def reset! = @calls = []
        end

        def execute(value: "x")
          self.class.calls << value
          Ask::Result.ok(data: "ran #{value}")
        end
      end

      class HashAdapter
        attr_reader :data

        def initialize
          @data = {}
        end

        def get(key) = @data[key]
        def set(key, value, ttl: nil) = @data[key] = value
        def delete(key) = @data.delete(key)
      end

      def build_chat_stub
        model_stub = OpenStruct.new(id: "gpt-4o", to_s: "gpt-4o")
        chat_stub = OpenStruct.new(model: model_stub, model_id: "gpt-4o")
        msgs = []
        chat_stub.define_singleton_method(:with_instructions) { |*| chat_stub }
        chat_stub.define_singleton_method(:add_message) { |role:, content: nil, **| msgs << Ask::Message.new(role: role, content: content) }
        chat_stub.define_singleton_method(:messages) { msgs }
        chat_stub.define_singleton_method(:reset_messages!) { msgs.clear }
        chat_stub
      end

      def new_session(store:, approval: true, **opts)
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        Session.new(model: "gpt-4o", tools: [CountingTool.new], state: store, approval: approval, **opts)
      end

      # --- Session persist/load ---

      def test_persist_includes_approval_snapshot
        store = HashAdapter.new
        s = new_session(store: store)
        s.approval_queue.submit(tool_call_id: "call_1", tool_name: "counting_tool", args: { "value" => "a" })
        s.send(:persist!)

        payload = store.get(s.id)
        refute_nil payload[:approvals], "persist! must store the queue snapshot"
        assert_equal 1, payload[:approvals][:version]
        assert_equal 1, payload[:approvals][:pending_actions].size
        assert_equal "call_1", payload[:approvals][:pending_actions].first[:tool_call_id]
      end

      def test_load_restores_pending_without_reemitting_and_approves_once
        CountingTool.reset!
        store = HashAdapter.new
        s = new_session(store: store)
        pending_events = []
        s.on(Events::ToolPending) { |e| pending_events << e }
        s.approval_queue.submit(tool_call_id: "call_1", tool_name: "counting_tool", args: { "value" => "a" })
        assert_equal 1, pending_events.size
        s.chat.add_message(role: :user, content: "hi")
        s.send(:persist!)

        restored = Session.load(s.id, adapter: store)
        refute_nil restored.approval_queue, "load must re-enable approval when pendings exist"
        assert_equal 1, restored.approval_queue.pending_actions.size
        action = restored.approval_queue.pending_actions.first
        assert_equal "call_1", action.tool_call_id
        # Restore must not emit another ToolPending.
        assert_equal 1, pending_events.size
        assert restored.pending_tools?, "pending-tool registration must survive load"
        # next_id preserved: a new submit must not reuse id 1.
        restored.stubs(:run_follow_up).returns(nil)
        new_id = restored.approval_queue.submit(tool_call_id: "call_2", tool_name: "counting_tool", args: {})
        refute_equal action.id, new_id
        restored.approval_queue.reject(new_id)

        restored.approval_queue.approve(action.id)
        assert_equal ["a"], CountingTool.calls
        assert_empty restored.approval_queue.pending_actions
        refute restored.pending_tools?
        # Second approve is a noop — the tool ran exactly once.
        restored.approval_queue.approve(action.id)
        assert_equal ["a"], CountingTool.calls
      end

      def test_load_without_approval_has_nil_snapshot_and_no_queue
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        s = Session.new(model: "gpt-4o", tools: [], state: store)
        s.chat.add_message(role: :user, content: "hi")
        s.send(:persist!)

        payload = store.get(s.id)
        assert_nil payload[:approvals]
        assert_nil payload[:plan_approvals]

        restored = Session.load(s.id, adapter: store)
        assert_nil restored.approval_queue
      end

      def test_load_with_empty_approvals_does_not_enable_queue
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        store.set("s1", {
          id: "s1",
          messages: [{ role: "user", content: "hi" }],
          approvals: { version: 1, next_id: 1, pending_actions: [] },
          metadata: { model: "gpt-4o", tools: [], max_turns: 25, turn_count: 0,
                      created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" }
        })
        restored = Session.load("s1", adapter: store)
        assert_nil restored.approval_queue
      end

      def test_plan_approvals_persist_and_restore
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        s = Session.new(model: "gpt-4o", tools: [], state: store, plan_mode: true)
        plan_events = []
        s.on(Events::ToolPending) { |e| plan_events << e }
        s.plan_queue.submit(tool_call_id: "plan_1", tool_name: "exit_plan_mode", args: { "plan" => "do it" })
        assert_equal 1, plan_events.size
        s.send(:persist!)

        payload = store.get(s.id)
        refute_nil payload[:plan_approvals]
        assert_equal "plan_1", payload[:plan_approvals][:pending_actions].first[:tool_call_id]

        restored = Session.load(s.id, adapter: store)
        assert restored.plan_mode?, "load must re-enable plan mode when a plan is pending"
        assert_equal 1, restored.plan_queue.pending_actions.size
        assert_equal "plan_1", restored.plan_queue.pending_actions.first.tool_call_id
        assert_equal 1, plan_events.size, "restore must not re-emit pending events"
      end

      # --- SessionAdapter snapshot/resume ---

      def test_adapter_snapshot_includes_approvals_and_resume_restores_once
        CountingTool.reset!
        host = Ask::Session::Host.new(store: Ask::Session::Store.new)
        store = HashAdapter.new
        s1 = new_session(store: store)
        adapter = SessionAdapter.create(agent: s1, host: host)
        s1.approval_queue.submit(tool_call_id: "call_9", tool_name: "counting_tool", args: { "value" => "z" })
        # Drive a run so the adapter appends a snapshot (chat stub answers "done").
        s1.define_singleton_method(:run) do |message, **|
          chat.add_message(role: :user, content: message)
          chat.add_message(role: :assistant, content: "done")
          "done"
        end
        # Stub messages for the snapshot: SessionAdapter reads agent.messages.
        s1.instance_variable_set(:@messages, s1.chat.messages.dup)
        adapter.send(:build_snapshot).tap do |snap|
          assert_equal 1, snap[:approvals][:pending_actions].size
        end
        adapter.run("hello")

        snapshot_event = host.events(s1.id).reverse_each.find { |e| e.type == "agent.snapshot" }
        refute_nil snapshot_event
        approvals = snapshot_event.payload[:approvals] || snapshot_event.payload["approvals"]
        refute_nil approvals, "adapter snapshot must carry approvals"
        assert_equal "call_9", (approvals[:pending_actions] || approvals["pending_actions"]).first[:tool_call_id] ||
          (approvals[:pending_actions] || approvals["pending_actions"]).first["tool_call_id"]

        # Resume into a fresh approval-enabled session: no re-emit, approve runs once.
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        s2 = Session.new(model: "gpt-4o", tools: [CountingTool.new], state: HashAdapter.new, approval: true)
        resumed_pending = []
        s2.on(Events::ToolPending) { |e| resumed_pending << e }
        SessionAdapter.resume(agent: s2, host: host, session_id: s1.id)

        assert_equal 1, s2.approval_queue.pending_actions.size
        assert_equal "call_9", s2.approval_queue.pending_actions.first.tool_call_id
        assert_empty resumed_pending, "resume must not re-emit approval-required events"
        assert s2.pending_tools?

        s2.stubs(:run_follow_up).returns(nil)
        s2.approval_queue.approve(s2.approval_queue.pending_actions.first.id)
        assert_equal ["z"], CountingTool.calls
        assert_empty s2.approval_queue.pending_actions
      end

      def test_adapter_resume_without_approvals_still_works
        host = Ask::Session::Host.new(store: Ask::Session::Store.new)
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        s1 = Session.new(model: "gpt-4o", tools: [], state: HashAdapter.new)
        s1.chat.add_message(role: :user, content: "hi")
        s1.instance_variable_set(:@messages, s1.chat.messages.dup)
        adapter = SessionAdapter.create(agent: s1, host: host)
        s1.define_singleton_method(:run) do |message, **|
          chat.add_message(role: :user, content: message)
          "ok"
        end
        adapter.run("hi")

        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        s2 = Session.new(model: "gpt-4o", tools: [], state: HashAdapter.new)
        resumed = SessionAdapter.resume(agent: s2, host: host, session_id: s1.id)
        refute_nil resumed
        assert_nil s2.approval_queue
      end

      # --- Malformed state must fail loudly (cannot strand pendings) ---

      def test_load_with_malformed_approvals_raises_contextual_error
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        store.set("bad1", {
          id: "bad1",
          messages: [{ role: "user", content: "hi" }],
          approvals: { version: 999, next_id: 1, pending_actions: [{ id: 1, tool_call_id: "c1", tool_name: "counting_tool", args: {} }] },
          metadata: { model: "gpt-4o", tools: [], max_turns: 25, turn_count: 0,
                      created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" }
        })
        err = assert_raises(Ask::Agent::Error) { Session.load("bad1", adapter: store) }
        assert_match(/approval/, err.message)
      end

      def test_load_with_non_array_pendings_raises
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        store.set("bad2", {
          id: "bad2",
          messages: [{ role: "user", content: "hi" }],
          approvals: { version: 1, next_id: 1, pending_actions: "bad" },
          metadata: { model: "gpt-4o", tools: [], max_turns: 25, turn_count: 0,
                      created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z" }
        })
        assert_raises(Ask::Agent::Error) { Session.load("bad2", adapter: store) }
      end

      def test_restore_into_nonempty_queue_raises_instead_of_stranding
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        s = Session.new(model: "gpt-4o", tools: [CountingTool.new], state: store, approval: true)
        s.approval_queue.submit(tool_call_id: "call_1", tool_name: "counting_tool", args: { "value" => "a" })
        snapshot = s.approval_queue.snapshot
        # Second restore into the same non-empty queue must raise, not drop either side.
        err = assert_raises(Ask::Agent::Error) do
          s.send(:restore_queue_snapshot, s.approval_queue, snapshot, "approval")
        end
        assert_match(/already holds pending/, err.message)
        assert_equal 1, s.approval_queue.pending_actions.size
      end

      def test_queue_snapshot_failure_raises_contextual_error
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        s = Session.new(model: "gpt-4o", tools: [], state: HashAdapter.new, approval: true)
        bad_queue = Object.new
        bad_queue.define_singleton_method(:snapshot) { raise "boom" }
        err = assert_raises(Ask::Agent::Error) do
          s.send(:queue_snapshot_for, bad_queue, "approval")
        end
        assert_match(/Failed to snapshot approval/, err.message)
      end

      def test_unsupported_queue_snapshot_fallback_returns_nil_without_stranding
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        s = Session.new(model: "gpt-4o", tools: [], state: HashAdapter.new)
        legacy_queue = Object.new # no #snapshot (pre-Permissions API)
        assert_nil s.send(:queue_snapshot_for, legacy_queue, "approval")
        # Restoring nil into any queue is a safe no-op.
        assert_nil s.send(:restore_queue_snapshot, nil, nil, "approval")
        assert_nil s.send(:restore_queue_snapshot, s.approval_queue, nil, "approval")
      end

      def test_persisted_tools_excludes_framework_tools
        Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
        store = HashAdapter.new
        s = Session.new(model: "gpt-4o", tools: [], state: store, plan_mode: true)
        s.chat.add_message(role: :user, content: "hi")
        s.send(:persist!)
        payload = store.get(s.id)
        tools = payload.dig(:metadata, :tools)
        refute_includes tools, "Ask::Agent::ExitPlanMode"
        refute_includes tools, "Ask::Skills::LoadSkillTool"
      end
    end
  end
end
