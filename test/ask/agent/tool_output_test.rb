# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

module Ask
  module Agent
    class ToolOutputTest < Minitest::Test
      class HugeTool < Ask::Tool
        description "Returns a huge output."
        def execute
          Ask::Result.ok(data: "line #{'x' * 100}\n" * 100) # ~10KB
        end
      end

      class SmallTool < Ask::Tool
        description "Returns a small output."
        def execute
          Ask::Result.ok(data: "tiny")
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

      class JsonAdapter < HashAdapter
        def get(key) = @data[key] && JSON.parse(JSON.generate(@data[key]))
        def set(key, value, ttl: nil) = @data[key] = value
      end

      class NullEmitter
        def emit(*) = nil
      end

      def setup
        @adapter = HashAdapter.new
        @store = ToolOutputStore.new(state: @adapter)
      end

      # -----------------------------------------------------------------
      # ToolOutputStore
      # -----------------------------------------------------------------

      def test_store_and_fetch_round_trip
        @store.store("s1", "call_1", "huge output content")

        assert_equal "huge output content", @store.fetch("s1", "call_1")
        assert_nil @store.fetch("s1", "missing")
      end

      def test_store_is_idempotent_per_call_id
        @store.store("s1", "call_1", "first")
        @store.store("s1", "call_1", "second")

        assert_equal "second", @store.fetch("s1", "call_1")
      end

      def test_store_truncates_beyond_max_size
        capped = ToolOutputStore.new(state: HashAdapter.new, max_size: 10)
        stored = capped.store("s1", "call_1", "a" * 50)

        assert_equal 10 + "\n...(output truncated)".length, stored.length
        assert_match(/truncated/, stored)
        assert_equal stored, capped.fetch("s1", "call_1")
      end

      def test_delete_removes_all_outputs_for_session
        @store.store("s1", "call_1", "one")
        @store.store("s1", "call_2", "two")
        @store.store("s2", "call_1", "other session")

        @store.delete("s1")

        assert_nil @store.fetch("s1", "call_1")
        assert_nil @store.fetch("s1", "call_2")
        assert_equal "other session", @store.fetch("s2", "call_1")
        assert_empty @adapter.data.keys.grep(/s1/)
      end

      def test_json_round_trip_survives_serialization
        json_adapter = JsonAdapter.new
        json_store = ToolOutputStore.new(state: json_adapter)
        json_store.store("s1", "call_1", "content")

        reloaded = ToolOutputStore.new(state: json_adapter)
        assert_equal "content", reloaded.fetch("s1", "call_1")
      end

      def test_works_with_minimal_get_set_adapter
        minimal = ToolOutputStore.new(state: HashAdapter.new)
        minimal.store("s1", "c", "x")
        assert_equal "x", minimal.fetch("s1", "c")
      end

      def test_concurrent_stores_are_safe
        threads = 8.times.map { |i| Thread.new { @store.store("s1", "call_#{i}", "out #{i}") } }
        threads.each(&:join)

        assert_equal "out 7", @store.fetch("s1", "call_7")
      end

      # -----------------------------------------------------------------
      # Executor offloading
      # -----------------------------------------------------------------

      def build_executor(**opts)
        ToolExecutor.new(max_retries: 1, parallel: false, output_store: @store, **opts)
      end

      def run_tool(executor, tool, id: "call_1")
        executor.execute(
          { id => ToolCallInfo.new(id: id, name: tool.name, arguments: "{}") },
          [tool],
          hooks: Hooks.new({}),
          event_emitter: NullEmitter.new,
          session_id: "s1"
        ).first
      end

      def test_large_output_is_offloaded
        executor = build_executor(output_offload_threshold: 100)
        result = run_tool(executor, HugeTool.new)

        refute_includes result[:message], "line x" * 5
        assert_match(/output_read id: "call_1"/, result[:message])
        assert_operator result[:message].length, :<, 500
        assert_match(/line x+/, @store.fetch("s1", "call_1"))
      end

      def test_small_output_is_not_offloaded
        executor = build_executor(output_offload_threshold: 100)
        result = run_tool(executor, SmallTool.new)

        assert_equal "tiny", result[:message]
        assert_nil @store.fetch("s1", "call_1")
      end

      def test_large_errors_are_offloaded
        failing = Class.new(Ask::Tool) do
          description "fails"
          def execute
            Ask::Result.error(message: "boom " * 500)
          end
        end.new
        executor = build_executor(output_offload_threshold: 100)

        result = run_tool(executor, failing)

        assert_equal true, result[:result][:is_error]
        assert_match(/output_read id: "call_1"/, result[:message])
        assert_includes @store.fetch("s1", "call_1"), "boom"
      end

      def test_offloading_disabled_by_default
        executor = build_executor # no threshold
        result = run_tool(executor, HugeTool.new)

        assert_operator result[:message].length, :>, 1000
        assert_nil @store.fetch("s1", "call_1")
      end

      # -----------------------------------------------------------------
      # Session integration
      # -----------------------------------------------------------------

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

      def test_session_option_wiring
        session = Session.new(model: "gpt-4o", offload_large_outputs: true)
        assert_instance_of ToolOutputStore, session.output_store
        names = session.instance_variable_get(:@tools).map(&:name)
        assert_includes names, "output_read"

        custom = Session.new(model: "gpt-4o", offload_large_outputs: 2000)
        assert_equal 2000, custom.instance_variable_get(:@offload_threshold)

        plain = Session.new(model: "gpt-4o")
        assert_nil plain.output_store
        refute_includes plain.instance_variable_get(:@tools).map(&:name), "output_read"
      end

      def test_session_offloads_end_to_end_and_output_read_recovers
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "huge")
          }),
          ResponseMessage.new(content: "", tool_calls: {
            "t2" => tool_call("t2", "output_read", JSON.generate(id: "t1"))
          }),
          ResponseMessage.new(content: "got it")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        session = Session.new(model: "gpt-4o", tools: [HugeTool.new], offload_large_outputs: true)
        result = session.run("Run the huge tool")

        assert_equal "got it", result
        tool_msgs = chat.messages.select { |m| m.role == :tool }
        # The huge tool's output never entered the transcript — only a
        # short preview with a reference.
        offloaded = tool_msgs.find { |m| m.content.to_s.include?("output_read id") }
        refute_nil offloaded
        assert_operator offloaded.content.length, :<, 500
        # The full output is stored and retrievable.
        assert_equal 10_600, session.output_store.fetch(session.id, "t1").length
        # output_read brought it back into context (exempt from offload).
        read_msg = tool_msgs.find { |m| m.content.to_s.include?("line") && m.content.to_s.length > 1000 }
        refute_nil read_msg
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_session_delete_cleans_up_outputs
        session = Session.new(model: "gpt-4o", offload_large_outputs: true)
        session.output_store.store(session.id, "call_1", "content")

        session.delete

        assert_nil session.output_store.fetch(session.id, "call_1")
      end
    end
  end
end
