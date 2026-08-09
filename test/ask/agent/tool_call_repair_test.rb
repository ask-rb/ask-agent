# frozen_string_literal: true

require_relative "../../test_helper"

module Ask
  module Agent
    class ToolCallRepairTest < Minitest::Test
      class RepairTest < Ask::Tool
        description "Echoes a value back."
        param :value, type: :integer, desc: "value to echo", required: true

        def execute(value:)
          Ask::Result.ok(data: "got #{value}")
        end
      end

      # Minimal Chat stand-in: records messages like the real Chat, serves
      # responses from a queue. Optionally raises on ask.
      class FakeChat
        attr_reader :messages, :ask_count

        def initialize(*responses, raise_on_ask: false)
          @responses = responses
          @messages = []
          @ask_count = 0
          @raise_on_ask = raise_on_ask
        end

        def ask(message = nil, attachments: nil)
          @ask_count += 1
          raise "repair ask failed" if @raise_on_ask

          @messages << Ask::Message.new(role: :user, content: message.to_s) if message
          response = @responses.shift || ResponseMessage.new(content: "done")
          @messages << Ask::Message.new(role: :assistant, content: response.content)
          response
        end

        def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil)
          @messages << Ask::Message.new(role: role, content: content, tool_call_id: tool_call_id, tool_calls: tool_calls)
        end
      end

      class NullEmitter
        def emit(*) = nil
      end

      def setup
        @tool = RepairTest.new
        @loop = Loop.new(max_turns: 5)
        @hooks = Hooks.new({})
      end

      def response(calls = {})
        ResponseMessage.new(
          content: "hi",
          tool_calls: calls,
          tool_results: {},
          thinking: nil,
          input_tokens: 1,
          output_tokens: 1,
          cost: 0.0
        )
      end

      def tool_call(id, name, arguments)
        ToolCallInfo.new(id: id, name: name, arguments: arguments)
      end

      def run_loop(chat, calls, tool_call_repair:)
        @loop.run_turn(
          chat: chat,
          message: "hello",
          tools: [@tool],
          tool_executor: ToolExecutor.new(max_retries: 1),
          compactor: nil,
          hooks: @hooks,
          event_emitter: NullEmitter.new,
          tool_call_repair: tool_call_repair
        )
      end

      # -----------------------------------------------------------------
      # ToolCallRepair.repair_info
      # -----------------------------------------------------------------

      def test_repair_info_valid_json_object_is_not_repairable
        tc = tool_call("c1", "repair_test", '{"value": 1}')
        assert_nil ToolCallRepair.repair_info(tc, [@tool])
      end

      def test_repair_info_hash_arguments_are_not_repairable
        tc = tool_call("c1", "repair_test", { "value" => 1 })
        assert_nil ToolCallRepair.repair_info(tc, [@tool])
      end

      def test_repair_info_unknown_tool_is_repairable
        tc = tool_call("c1", "no_such_tool", "{}")
        assert_match(/unknown tool/, ToolCallRepair.repair_info(tc, [@tool]))
      end

      def test_repair_info_malformed_json_is_repairable
        tc = tool_call("c1", "repair_test", "{not json")
        assert_match(/not valid JSON/, ToolCallRepair.repair_info(tc, [@tool]))
      end

      def test_repair_info_non_object_json_is_repairable
        tc = tool_call("c1", "repair_test", "[1, 2]")
        assert_match(/must be a JSON object/, ToolCallRepair.repair_info(tc, [@tool]))
      end

      # -----------------------------------------------------------------
      # ToolCallRepair#call
      # -----------------------------------------------------------------

      def test_built_in_repair_remaps_corrections_to_original_ids_and_restores_history
        chat = FakeChat.new(
          response({ "new1" => tool_call("new1", "repair_test", '{"value": 42}') })
        )
        calls = { "orig1" => tool_call("orig1", "repair_test", "{bad") }

        corrections = ToolCallRepair.new.call(chat: chat, calls: calls, tools: [@tool])

        assert_equal ["orig1"], corrections.keys
        assert_equal "repair_test", corrections["orig1"].name
        assert_equal '{"value": 42}', corrections["orig1"].arguments
        # The internal repair exchange is removed from history.
        assert_empty chat.messages
      end

      def test_built_in_repair_with_fewer_corrections_returns_only_those
        chat = FakeChat.new(
          response({ "new1" => tool_call("new1", "repair_test", '{"value": 1}') })
        )
        calls = {
          "orig1" => tool_call("orig1", "repair_test", "{bad"),
          "orig2" => tool_call("orig2", "no_such_tool", "{}")
        }

        corrections = ToolCallRepair.new.call(chat: chat, calls: calls, tools: [@tool])

        assert_equal ["orig1"], corrections.keys
      end

      def test_built_in_repair_failure_returns_empty_and_restores_history
        chat = FakeChat.new(raise_on_ask: true)

        corrections = ToolCallRepair.new.call(
          chat: chat, calls: { "orig1" => tool_call("orig1", "repair_test", "{bad") }, tools: [@tool]
        )

        assert_equal({}, corrections)
        assert_empty chat.messages
      end

      def test_custom_callable_is_used_and_normalized
        captured = nil
        callable = lambda do |chat, calls, tools|
          captured = [chat, calls, tools]
          { calls.keys.first => ToolCallInfo.new(id: calls.keys.first, name: "repair_test", arguments: '{"value": 3}') }
        end
        chat = FakeChat.new
        calls = { "orig1" => tool_call("orig1", "repair_test", "{bad") }

        corrections = ToolCallRepair.new(callable).call(chat: chat, calls: calls, tools: [@tool])

        assert_equal [chat, calls, [@tool]], captured
        assert_equal '{"value": 3}', corrections["orig1"].arguments
        assert_equal "orig1", corrections["orig1"].id
        assert_equal 0, chat.ask_count # custom callable did not hit the LLM
      end

      def test_custom_callable_returning_garbage_yields_empty
        corrections = ToolCallRepair.new(->(_c, _calls, _t) { "nope" }).call(
          chat: FakeChat.new, calls: { "orig1" => tool_call("orig1", "repair_test", "{bad") }, tools: [@tool]
        )
        assert_equal({}, corrections)
      end

      # -----------------------------------------------------------------
      # Loop integration
      # -----------------------------------------------------------------

      def test_loop_repairs_malformed_arguments_and_executes_the_corrected_call
        chat = FakeChat.new(
          response({ "c1" => tool_call("c1", "repair_test", "{not json") }),
          response({ "x" => tool_call("x", "repair_test", '{"value": 42}') }),
          response({})
        )

        result = run_loop(chat, nil, tool_call_repair: true)

        assert_equal "hi", result
        tool_messages = chat.messages.select { |m| m.role == :tool }
        assert_equal ["got 42"], tool_messages.map(&:content)
        # The internal repair exchange never reaches the conversation.
        refute chat.messages.any? { |m| m.content.to_s.include?("Some tool calls from your last message") }
      end

      def test_loop_repairs_unknown_tool_name
        chat = FakeChat.new(
          response({ "c1" => tool_call("c1", "no_such_tool", "{}") }),
          response({ "x" => tool_call("x", "repair_test", '{"value": 7}') }),
          response({})
        )

        result = run_loop(chat, nil, tool_call_repair: true)

        assert_equal "hi", result
        assert_equal ["got 7"], chat.messages.select { |m| m.role == :tool }.map(&:content)
      end

      def test_loop_drops_malformed_calls_the_model_cannot_correct
        chat = FakeChat.new(
          response({ "c1" => tool_call("c1", "no_such_tool", "{}") }),
          response({}), # repair reply: no corrections
          response({})
        )

        result = run_loop(chat, nil, tool_call_repair: true)

        assert_equal "hi", result
        assert_empty chat.messages.select { |m| m.role == :tool }
      end

      def test_loop_without_repair_executes_malformed_call_as_before
        chat = FakeChat.new(
          response({ "c1" => tool_call("c1", "repair_test", "{not json") }),
          response({})
        )

        result = run_loop(chat, nil, tool_call_repair: nil)

        assert_equal "hi", result
        tool_messages = chat.messages.select { |m| m.role == :tool }
        assert_equal 1, tool_messages.size
        assert_match(/error/i, tool_messages.first.content)
        # No repair round-trip happened: only the initial ask and the
        # follow-up ask (2 asks total).
        assert_equal 2, chat.ask_count
      end

      def test_loop_uses_custom_repair_callable
        callable = lambda do |_chat, calls, _tools|
          { calls.keys.first => tool_call(calls.keys.first, "repair_test", '{"value": 9}') }
        end
        chat = FakeChat.new(
          response({ "c1" => tool_call("c1", "repair_test", "{bad") }),
          response({})
        )

        result = run_loop(chat, nil, tool_call_repair: callable)

        assert_equal "hi", result
        assert_equal ["got 9"], chat.messages.select { |m| m.role == :tool }.map(&:content)
        assert_equal 2, chat.ask_count # custom repair never called the LLM
      end

      def test_loop_emits_tool_call_repaired_event
        emitted = []
        emitter = Class.new do
          define_method(:emit) { |event| emitted << event }
        end.new
        chat = FakeChat.new(
          response({ "c1" => tool_call("c1", "repair_test", "{bad") }),
          response({ "x" => tool_call("x", "repair_test", '{"value": 5}') }),
          response({})
        )

        @loop.run_turn(
          chat: chat, message: "hello", tools: [@tool],
          tool_executor: ToolExecutor.new(max_retries: 1),
          compactor: nil, hooks: @hooks, event_emitter: emitter,
          tool_call_repair: true
        )

        repaired = emitted.find { |e| e.is_a?(Events::ToolCallRepaired) }
        refute_nil repaired
        assert_equal "c1", repaired.id
        assert_equal "repair_test", repaired.name
        assert_equal "{bad", repaired.original_arguments
        assert_equal '{"value": 5}', repaired.corrected_arguments
      end
    end
  end
end
