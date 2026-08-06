# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

module Ask
  module Agent
    class TodoPlanTest < Minitest::Test
      class PlanWriteTool < Ask::Tool
        description "Writes something (side effect)."
        def execute
          self.class.executions += 1
          Ask::Result.ok(data: "wrote #{self.class.executions}")
        end

        def self.executions = @executions ||= 0
        def self.executions=(n)
          @executions = n
        end
      end

      class PlanReadTool < Ask::Tool
        description "Reads something."
        def execute
          Ask::Result.ok(data: "read result")
        end
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

      ResponseMessage = Data.define(:content, :tool_calls, :tool_results, :thinking, :input_tokens, :output_tokens, :cost) do
        def initialize(content:, tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
          super(content: content, tool_calls: tool_calls, tool_results: tool_results, thinking: thinking,
                input_tokens: input_tokens, output_tokens: output_tokens, cost: cost)
        end

        def tool_call? = !tool_calls.empty?
        def to_s = content.to_s
      end

      def tool_call(id, name, arguments = "{}")
        ToolCallInfo.new(id: id, name: name, arguments: arguments)
      end

      def setup
        PlanWriteTool.executions = 0
        @emitted = []
      end

      def build_session(**opts)
        session = Session.new(model: "gpt-4o", **opts)
        session.on(:all) { |event| @emitted << event }
        session
      end

      # -----------------------------------------------------------------
      # TodoList
      # -----------------------------------------------------------------

      def test_todo_list_add_update_clear
        list = TodoList.new
        first = list.add("Investigate the error")
        second = list.add("Fix it", status: "in_progress")

        assert_equal "todo_1", first.id
        assert_equal "pending", first.status
        assert_equal "in_progress", second.status
        assert_equal 2, list.all.size

        updated = list.update(first.id, status: "completed")
        assert_equal "completed", updated.status

        list.clear
        assert_empty list.all
      end

      def test_todo_list_validates_inputs
        list = TodoList.new
        assert_raises(ArgumentError) { list.add("") }
        assert_raises(ArgumentError) { list.add("x", status: "bogus") }
        assert_raises(ArgumentError) { list.update("todo_99") }
        list.add("x")
        assert_raises(ArgumentError) { list.update("todo_1", status: "bogus") }
      end

      def test_todo_list_serialization_round_trip
        list = TodoList.new
        list.add("Plan", status: "in_progress")
        list.add("Execute")

        restored = TodoList.new
        restored.restore(list.to_h)
        assert_equal 2, restored.all.size
        assert_equal "in_progress", restored.all.first.status
        assert_equal "todo_3", restored.add("Next").id # ids continue

        # String-keyed payloads (JSON round-trips) restore too.
        restored2 = TodoList.new
        restored2.restore(JSON.parse(JSON.generate(list.to_h)))
        assert_equal 2, restored2.all.size
      end

      def test_todo_list_subscribers_fire_on_changes_not_restore
        list = TodoList.new
        snapshots = []
        list.subscribe { |entries| snapshots << entries }

        list.add("One")
        list.update("todo_1", status: "completed")
        list.clear
        assert_equal 3, snapshots.size

        list.restore({ "entries" => [{ "id" => "x", "title" => "y", "status" => "pending" }] })
        assert_equal 3, snapshots.size # restore fires no events
      end

      def test_todo_list_to_s
        list = TodoList.new
        list.add("Fix the bug")
        assert_match(/\[pending\] Fix the bug/, list.to_s)
      end

      # -----------------------------------------------------------------
      # TodoWrite tool
      # -----------------------------------------------------------------

      def test_todo_write_tool_actions
        list = TodoList.new
        tool = TodoWrite.new(todo_list: list)

        result = tool.call(action: "add", title: "Step one")
        assert_predicate result, :ok?
        assert_match(/Step one/, result.to_s)
        assert_equal 1, list.all.size

        result = tool.call(action: "update", id: "todo_1", status: "completed")
        assert_predicate result, :ok?
        assert_equal "completed", list.all.first.status

        result = tool.call(action: "list")
        assert_predicate result, :ok?
        assert_match(/completed/, result.to_s)

        result = tool.call(action: "clear")
        assert_predicate result, :ok?
        assert_empty list.all
      end

      def test_todo_write_tool_errors
        tool = TodoWrite.new(todo_list: TodoList.new)
        assert_predicate tool.call(action: "bogus"), :error
        assert_predicate tool.call(action: "add"), :error # missing title
        assert_predicate tool.call(action: "add", title: "x", status: "bogus"), :error
      end

      def test_todo_write_name
        assert_equal "todo_write", TodoWrite.new(todo_list: TodoList.new).name
      end

      # -----------------------------------------------------------------
      # Session: todos
      # -----------------------------------------------------------------

      def test_session_todos_option_injects_tool_and_emits_events
        session = build_session(todos: true, tools: [])
        assert_instance_of TodoList, session.todo_list
        assert_includes session.instance_variable_get(:@tools).map(&:name), "todo_write"

        session.todo_list.add("Plan the migration")
        todo_events = @emitted.select { |e| e.is_a?(Events::TodoUpdated) }
        assert_equal 1, todo_events.size
        assert_equal "Plan the migration", todo_events.first.todos.first.title
      end

      def test_todo_write_runs_end_to_end_and_persists
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "todo_write", JSON.generate(action: "add", title: "Investigate"))
          }),
          ResponseMessage.new(content: "planned")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)
        store = Ask::State::Memory.new

        session = build_session(todos: true, state: store, checkpoints: true)
        result = session.run("Plan this job")

        assert_equal "planned", result
        assert_equal "Investigate", session.todo_list.all.first.title
        # Todos are part of the checkpoint snapshot.
        snapshot = session.load_checkpoint
        assert_equal "Investigate", snapshot[:todos][:entries].first[:title]
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_rollback_restores_todos
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "todo_write", JSON.generate(action: "add", title: "First"))
          }),
          ResponseMessage.new(content: "", tool_calls: {
            "t2" => tool_call("t2", "todo_write", JSON.generate(action: "add", title: "Second"))
          }),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)
        store = Ask::State::Memory.new

        session = build_session(todos: true, state: store, checkpoints: true)
        session.run("Plan")

        assert_equal 2, session.todo_list.all.size
        session.rollback!(seq: 1)
        assert_equal 1, session.todo_list.all.size
        assert_equal "First", session.todo_list.all.first.title
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      # -----------------------------------------------------------------
      # Session: plan mode
      # -----------------------------------------------------------------

      def test_plan_mode_injects_exit_tool_and_starts_in_plan_mode
        session = build_session(plan_mode: true, tools: [PlanWriteTool.new])
        assert_predicate session, :plan_mode?
        assert_instance_of ApprovalQueue, session.plan_queue
        assert_includes session.instance_variable_get(:@tools).map(&:name), "exit_plan_mode"
      end

      def test_plan_mode_blocks_mutating_tools_and_allows_read_only
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "plan_write")
          }),
          ResponseMessage.new(content: "", tool_calls: {
            "t2" => tool_call("t2", "plan_read")
          }),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        session = build_session(
          plan_mode: { read_only_tools: %w[plan_read] },
          tools: [PlanWriteTool.new, PlanReadTool.new]
        )

        session.run("Research then act")

        # plan_write was blocked (never executed); plan_read ran.
        assert_equal 0, PlanWriteTool.executions
        assert_includes session.chat.messages.map(&:content).join, "Plan mode"
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_plan_approval_turns_off_plan_mode_and_unblocks_tools
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "exit_plan_mode", JSON.generate(plan: "Step 1: write the file"))
          }),
          # Follow-up after approval: the model executes the approved plan.
          ResponseMessage.new(content: "", tool_calls: {
            "t2" => tool_call("t2", "plan_write")
          }),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        session = build_session(
          plan_mode: { read_only_tools: %w[plan_read] },
          tools: [PlanWriteTool.new]
        )

        session.run("Research and propose a plan")
        assert_predicate session, :plan_mode?

        # The plan sits in the plan queue awaiting a human decision.
        action = session.plan_queue.pending_actions.first
        refute_nil action
        assert_equal "exit_plan_mode", action.tool_name
        assert_equal "Step 1: write the file", action.args[:plan]
        proposed = @emitted.find { |e| e.is_a?(Events::PlanProposed) }
        assert_equal "Step 1: write the file", proposed.plan

        session.plan_queue.approve(action.id)

        refute_predicate session, :plan_mode?
        assert_equal 1, PlanWriteTool.executions
        assert @emitted.any? { |e| e.is_a?(Events::PlanApproved) }
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_plan_rejection_keeps_plan_mode
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "exit_plan_mode", JSON.generate(plan: "My plan"))
          }),
          ResponseMessage.new(content: "revising")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        session = build_session(plan_mode: true, tools: [PlanWriteTool.new])

        session.run("Propose a plan")
        action = session.plan_queue.pending_actions.first
        session.plan_queue.reject(action.id)

        assert_predicate session, :plan_mode?
        assert_equal 0, PlanWriteTool.executions
        assert @emitted.any? { |e| e.is_a?(Events::PlanRejected) }
        # The rejection feedback reached the conversation.
        assert_includes session.chat.messages.map(&:content).join, "Plan rejected"
      ensure
        Ask::Agent::Chat.unstub(:new)
      end
    end
  end
end
