# frozen_string_literal: true

require_relative "../../test_helper"

# Session.load resolves tool class names with String#constantize
# (ActiveSupport). Provide a minimal version when it is not loaded.
unless String.method_defined?(:constantize)
  class String
    def constantize
      split("::").reject(&:empty?).inject(Object) { |obj, const| obj.const_get(const) }
    end
  end
end

module Ask
  module Agent
    class CheckpointTest < Minitest::Test
      class CheckpointProbe < Ask::Tool
        description "Echoes a number."
        param :value, type: :integer, desc: "value to echo", required: true

        def execute(value:)
          Ask::Result.ok(data: "echo #{value}")
        end
      end

      # Tool that cannot be auto-instantiated (requires a constructor kwarg).
      class RegistryTool < Ask::Tool
        def initialize(registry:)
          @registry = registry
          super()
        end

        def execute(*) = Ask::Result.ok(data: 1)
      end

      # Durable adapter backed by a Hash.
      class HashAdapter
        attr_reader :data

        def initialize
          @data = {}
        end

        def get(key) = @data[key]
        def set(key, value, ttl: nil) = @data[key] = value
        def delete(key) = @data.delete(key)
      end

      # Chat stand-in with ask support, so Session#run drives real turns.
      class TurnChat
        attr_reader :messages, :model, :model_id

        def initialize(*responses)
          @responses = responses
          @messages = []
          @model = OpenStruct.new(id: "gpt-4o")
          @model_id = "gpt-4o"
        end

        def with_instructions(*) = self

        def ask(message = nil)
          @messages << Ask::Message.new(role: :user, content: message.to_s) if message
          response = @responses.shift || ResponseMessage.new(content: "done")
          @messages << Ask::Message.new(role: :assistant, content: response.content)
          response
        end

        def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil)
          @messages << Ask::Message.new(role: role, content: content, tool_call_id: tool_call_id, tool_calls: tool_calls)
        end

        def reset_messages! = @messages.clear
      end

      def setup
        @adapter = HashAdapter.new
        @session = Session.new(
          model: "gpt-4o",
          tools: [CheckpointProbe.new],
          state: @adapter,
          checkpoints: true
        )
      end

      def add_turn(messages)
        messages.each { |m| @session.chat.add_message(**m) }
        @session.instance_variable_set(:@turn_count, @session.instance_variable_get(:@turn_count) + 1)
        @session.save
      end

      # -----------------------------------------------------------------
      # Enabling
      # -----------------------------------------------------------------

      def test_checkpoints_require_state_adapter
        error = assert_raises(ArgumentError) do
          Session.new(model: "gpt-4o", checkpoints: true)
        end
        assert_match(/requires a state/, error.message)
      end

      def test_no_checkpoints_by_default
        plain = Session.new(model: "gpt-4o", state: HashAdapter.new)
        plain.chat.add_message(role: :user, content: "hi")
        plain.save

        assert_nil plain.instance_variable_get(:@checkpoint_store)
        assert_empty @adapter.data.keys.grep(/:checkpoint:/)
      end

      def test_checkpoint_history_raises_without_checkpoints
        plain = Session.new(model: "gpt-4o", state: HashAdapter.new)
        assert_raises(RuntimeError) { plain.checkpoint_history }
      end

      # -----------------------------------------------------------------
      # Saving
      # -----------------------------------------------------------------

      def test_save_writes_one_checkpoint_per_turn
        add_turn([{ role: :user, content: "hi" }, { role: :assistant, content: "hello" }])
        add_turn([{ role: :user, content: "again" }, { role: :assistant, content: "sure" }])

        assert_equal [1, 2], @session.checkpoint_history
        snapshot = @session.load_checkpoint(seq: 1)
        assert_equal 1, snapshot[:metadata][:turn_count]
        assert_equal "hi", snapshot[:messages].first[:content]
        snapshot2 = @session.load_checkpoint(seq: 2)
        assert_equal 2, snapshot2[:metadata][:turn_count]
        assert_equal "sure", snapshot2[:messages].last[:content]
      end

      # -----------------------------------------------------------------
      # Rollback
      # -----------------------------------------------------------------

      def test_rollback_restores_messages_turn_count_and_head
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        @session.rollback!(seq: 1)

        contents = @session.chat.messages.map(&:content)
        assert_equal %w[q1 a1], contents
        assert_equal 1, @session.instance_variable_get(:@turn_count)
        assert_equal 1, @session.checkpoint_history.last
        # The legacy blob matches the restored state too.
        restored = @adapter.get(@session.id)
        assert_equal "q1", restored[:messages].first[:content]
      end

      def test_rollback_by_turn
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        @session.rollback!(turn: 1)

        assert_equal %w[q1 a1], @session.chat.messages.map(&:content)
      end

      def test_rollback_to_missing_checkpoint_raises
        add_turn([{ role: :user, content: "q1" }])
        assert_raises(ArgumentError) { @session.rollback!(seq: 99) }
        assert_raises(ArgumentError) { @session.rollback!(turn: 7) }
        assert_raises(ArgumentError) { @session.rollback! }
      end

      def test_rollback_requires_seq_or_turn
        add_turn([{ role: :user, content: "q1" }])
        assert_raises(ArgumentError) { @session.rollback!(seq: 1, turn: 1) }
      end

      def test_rollback_rejects_running_session
        @session.instance_variable_set(:@running, true)
        add_turn([{ role: :user, content: "q1" }])
        @session.instance_variable_set(:@running, false) # add_turn works while running
        @session.instance_variable_set(:@running, true)
        assert_raises(RuntimeError) { @session.rollback!(seq: 1) }
      end

      def test_session_continues_after_rollback
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        @session.rollback!(seq: 1)
        add_turn([{ role: :user, content: "q3" }, { role: :assistant, content: "a3" }])

        # The new turn appends after the rolled-back head (seq 2), so the
        # timeline is 1 (old), 2 (new turn 2) — history stays contiguous.
        assert_equal [1, 2], @session.checkpoint_history
        assert_equal "a3", @session.chat.messages.last.content
      end

      def test_rollback_emits_event
        emitted = []
        @session.on(:all) { |event| emitted << event }
        add_turn([{ role: :user, content: "q1" }])

        @session.rollback!(seq: 1)

        event = emitted.find { |e| e.is_a?(Events::SessionRolledBack) }
        refute_nil event
        assert_equal @session.id, event.session_id
        assert_equal 1, event.seq
        assert_equal 1, event.turn_count
      end

      # -----------------------------------------------------------------
      # Fork
      # -----------------------------------------------------------------

      def test_fork_creates_branch_with_matching_history
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        forked = @session.fork(at_seq: 1)

        refute_equal @session.id, forked.id
        assert_equal %w[q1 a1], forked.chat.messages.map(&:content)
        assert_equal 1, forked.instance_variable_get(:@turn_count)
        assert_equal [1], forked.checkpoint_history
        # Original untouched.
        assert_equal [1, 2], @session.checkpoint_history
      end

      def test_fork_by_turn
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        forked = @session.fork(at_turn: 2)

        assert_equal %w[q1 a1 q2 a2], forked.chat.messages.map(&:content)
        assert_equal [1, 2], forked.checkpoint_history
      end

      def test_forked_session_is_independent
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        forked = @session.fork(at_seq: 1)
        forked.chat.add_message(role: :user, content: "branch question")
        forked.save

        # The branch's history grows; the original's does not.
        assert_equal [1, 2], forked.checkpoint_history
        assert_equal [1, 2], @session.checkpoint_history
        assert_equal "branch question", forked.chat.messages.last.content
        assert_equal "a2", @session.chat.messages.last.content
      end

      def test_fork_missing_checkpoint_raises
        add_turn([{ role: :user, content: "q1" }])
        assert_raises(ArgumentError) { @session.fork(at_seq: 42) }
      end

      def test_fork_emits_event
        emitted = []
        @session.on(:all) { |event| emitted << event }
        add_turn([{ role: :user, content: "q1" }])

        forked = @session.fork(at_seq: 1)

        event = emitted.find { |e| e.is_a?(Events::SessionForked) }
        refute_nil event
        assert_equal @session.id, event.session_id
        assert_equal forked.id, event.forked_id
      end

      # -----------------------------------------------------------------
      # Load & delete
      # -----------------------------------------------------------------

      def test_load_restores_checkpointing_automatically
        add_turn([{ role: :user, content: "q1" }, { role: :assistant, content: "a1" }])
        add_turn([{ role: :user, content: "q2" }, { role: :assistant, content: "a2" }])

        restored = Session.load(@session.id, adapter: @adapter)

        assert_equal [1, 2], restored.checkpoint_history
        restored.rollback!(seq: 1)
        assert_equal %w[q1 a1], restored.chat.messages.map(&:content)
      end

      # -----------------------------------------------------------------
      # Tool restore
      # -----------------------------------------------------------------

      def test_persist_excludes_framework_injected_load_skill_tool
        add_turn([{ role: :user, content: "q1" }])

        tools = @adapter.get(@session.id)[:metadata][:tools]
        assert_equal ["Ask::Agent::CheckpointTest::CheckpointProbe"], tools

        # The user tool is restored by class name; framework-injected tools
        # are never persisted (resolve_tools re-adds load_skill per-session).
        restored = Session.load(@session.id, adapter: @adapter)
        assert_includes restored.instance_variable_get(:@tools).map(&:name), "checkpoint_probe"
      end

      def test_load_skips_and_warns_on_unrestorable_tool_class
        store = HashAdapter.new
        store.set("s1", {
          id: "s1",
          messages: [{ role: "user", content: "hi" }],
          metadata: {
            model: "gpt-4o",
            tools: ["No::Such::Tool", "Ask::Agent::CheckpointTest::CheckpointProbe"],
            max_turns: 5, turn_count: 1,
            created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
          }
        })

        restored = nil
        _out, err = capture_io do
          restored = Session.load("s1", adapter: store)
        end

        assert_match(/skipped tool 'No::Such::Tool'/, err)
        refute_nil restored
        names = restored.instance_variable_get(:@tools).map(&:name)
        assert_includes names, "checkpoint_probe"
        refute_includes names, "no_such_tool"
      end

      def test_load_skips_and_warns_on_tool_with_required_constructor_args
        store = HashAdapter.new
        store.set("s2", {
          id: "s2",
          messages: [{ role: "user", content: "hi" }],
          metadata: {
            model: "gpt-4o",
            tools: ["Ask::Agent::CheckpointTest::RegistryTool"],
            max_turns: 5, turn_count: 1,
            created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
          }
        })

        restored = nil
        _out, err = capture_io do
          restored = Session.load("s2", adapter: store)
        end

        assert_match(/skipped tool 'Ask::Agent::CheckpointTest::RegistryTool'/, err)
        refute_nil restored
        # No user tools survived; only framework-injected tools (if skills
        # disclosure is active in this context) remain.
        names = restored.instance_variable_get(:@tools).map(&:name)
        refute_includes names, "registry_tool"
        refute_includes names, "registry"
      end

      def test_delete_removes_session_and_checkpoints
        add_turn([{ role: :user, content: "q1" }])

        @session.delete

        assert_nil @adapter.get(@session.id)
        assert_empty @adapter.data.keys.grep(/#{@session.id}/)
        assert_nil Session.load(@session.id, adapter: @adapter)
      end

      # -----------------------------------------------------------------
      # End to end: real turns
      # -----------------------------------------------------------------

      def test_run_persists_checkpoints_per_turn
        chat = TurnChat.new(
          ResponseMessage.new(
            content: "",
            tool_calls: { "t1" => ToolCallInfo.new(id: "t1", name: "checkpoint_probe", arguments: '{"value": 3}') }
          ),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        # Build the session AFTER stubbing so it gets the TurnChat.
        session = Session.new(
          model: "gpt-4o",
          tools: [CheckpointProbe.new],
          state: @adapter,
          checkpoints: true
        )

        result = session.run("start")

        assert_equal "done", result
        # Exactly 2 turns → exactly 2 checkpoints. The run-end persist!
        # must not append a duplicate tail checkpoint.
        assert_equal [1, 2], session.checkpoint_history
        # The tool executed as part of a real turn, and the rollback API can
        # rewind to the first turn.
        session.rollback!(seq: 1)
        assert_equal "start", session.chat.messages.first.content
      ensure
        Ask::Agent::Chat.unstub(:new)
      end
    end
  end
end
