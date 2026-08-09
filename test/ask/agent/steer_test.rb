# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

module Ask
  module Agent
    class SteerTest < Minitest::Test
      # Tool that steers the running session mid-turn (like an external
      # client would from another thread).
      class SteerProbe < Ask::Tool
        description "steers"
        def execute
          result = Ask::Agent.current_session.steer("interrupt!", expected_turn_id: 1)
          Ask::Result.ok(data: "steer: #{result[:status]}")
        end
      end

      class TurnChat
        attr_reader :messages, :model, :model_id

        def initialize(*responses)
          @responses = responses
          @messages = []
          @model = OpenStruct.new(id: "gpt-4o")
          @model_id = "gpt-4o"
        end

        def with_instructions(*) = self

        def ask(message = nil, attachments: nil)
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
        @session = Session.new(model: "gpt-4o")
      end

      # -----------------------------------------------------------------
      # steer API
      # -----------------------------------------------------------------

      def test_steer_while_idle_adds_message
        result = @session.steer("Do it this way")

        assert_equal :steered, result[:status]
        assert_equal 0, result[:turn_id]
        assert_equal "Do it this way", @session.chat.messages.last.content
        assert_equal 0, @session.queued_steers
      end

      def test_steer_with_matching_expected_turn_is_queued_while_running
        @session.instance_variable_set(:@running, true)
        @session.instance_variable_set(:@turn_id, 2)

        result = @session.steer("steer now", expected_turn_id: 2)

        assert_equal :queued, result[:status]
        assert_equal 1, @session.queued_steers
      end

      def test_steer_with_stale_expected_turn_is_rejected
        @session.instance_variable_set(:@running, true)
        @session.instance_variable_set(:@turn_id, 2)

        result = @session.steer("stale steer", expected_turn_id: 1)

        assert_equal :stale, result[:status]
        assert_equal 2, result[:turn_id]
        assert_equal 0, @session.queued_steers
      end

      def test_turn_id_tracks_turns
        assert_equal 0, @session.turn_id
        @session.emit(Events::TurnStart.new)
        assert_equal 1, @session.turn_id
        @session.emit(Events::TurnStart.new)
        assert_equal 2, @session.turn_id
      end

      # -----------------------------------------------------------------
      # End to end: steer dispatched at the next turn boundary
      # -----------------------------------------------------------------

      def test_steer_during_a_turn_is_dispatched_at_the_next_boundary
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "steer_probe")
          }),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)
        session = Session.new(model: "gpt-4o", tools: [SteerProbe.new])

        result = session.run("start")

        assert_equal "done", result
        # The steer was queued mid-turn (tool reported :queued) and became
        # the next user message.
        steer_msg = chat.messages.select { |m| m.role == :user }.map(&:content)
        assert_includes steer_msg, "interrupt!"
        assert_equal 0, session.queued_steers
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_queued_steers_drain_at_next_run_start
        # Queue two steers by hand (as if they arrived during a run).
        @session.instance_variable_set(:@running, true)
        @session.instance_variable_set(:@turn_id, 1)
        @session.steer("first", expected_turn_id: 1)
        @session.steer("second", expected_turn_id: 1)
        @session.instance_variable_set(:@running, false)

        chat = TurnChat.new(ResponseMessage.new(content: "ok"))
        Ask::Agent::Chat.stubs(:new).returns(chat)
        session = Session.new(model: "gpt-4o")
        # Move the queued steers onto this session for the drain test.
        session.instance_variable_set(:@queued_steers, @session.instance_variable_get(:@queued_steers))

        session.run("go")

        users = session.chat.messages.select { |m| m.role == :user }.map(&:content)
        assert_includes users, "first"
        assert_includes users, "second"
        assert_equal 0, session.queued_steers
      ensure
        Ask::Agent::Chat.unstub(:new)
      end
    end
  end
end
