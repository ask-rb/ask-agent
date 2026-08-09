# frozen_string_literal: true

require_relative "../../test_helper"
require "ask/tools/tool"

# Async (pending) tool support: a tool returns Ask::Result.pending, the
# turn hands back with the interim reply, and Session#complete_pending_tool
# voices the answer when the background work finishes.
class AsyncToolTest < Minitest::Test
  class RecordingEmitter
    attr_reader :registered, :completed, :pending_events

    def initialize
      @registered = []
      @completed = []
      @pending_events = []
    end

    def register_pending_tool(id, result)
      @registered << [id, result]
    end

    def emit(event)
      @pending_events << event if event.is_a?(Ask::Agent::Events::ToolPending)
      @completed << event if event.is_a?(Ask::Agent::Events::ToolCompleted)
    end

    def abort_requested? = false
  end

  def setup
    @hooks = Ask::Agent::Hooks.new({})
  end

  # A scripted chat: first ask returns a tool call, follow-ups return text.
  class ScriptedChat
    attr_reader :asks, :messages

    def initialize(emitter: nil, final_text: "We're open until five.", tool_name: "slow_tool")
      @asks = 0
      @emitter = emitter
      @final_text = final_text
      @tool_name = tool_name
      @messages = []
    end

    def add_message(role:, content:, tool_call_id: nil)
      @messages << {role: role, content: content, tool_call_id: tool_call_id}
    end

    def ask(_message, attachments: nil)
      @asks += 1
      if @asks == 1
        Ask::Agent::ResponseMessage.new(
          content: "Let me check that for you.",
          tool_calls: {"c1" => Ask::Agent::ToolCallInfo.new(id: "c1", name: @tool_name, arguments: "{}")},
          tool_results: {}, thinking: nil, input_tokens: 1, output_tokens: 1, cost: 0.0
        )
      else
        Ask::Agent::ResponseMessage.new(
          content: @final_text, tool_calls: {}, tool_results: {}, thinking: nil,
          input_tokens: 1, output_tokens: 1, cost: 0.0
        )
      end
    end
  end

  def test_loop_returns_interim_content_and_registers_pending_tool
    chat = ScriptedChat.new
    tool = stub(name: "slow_tool")
    tool.stubs(:call).returns(Ask::Result.pending("Research started"))
    executor = Ask::Agent::ToolExecutor.new
    emitter = RecordingEmitter.new
    loop = Ask::Agent::Loop.new(max_turns: 5)

    result = loop.run_turn(
      chat: chat, message: "What are your hours?", tools: [tool],
      tool_executor: executor, compactor: nil, hooks: @hooks, event_emitter: emitter
    )

    assert_equal "Let me check that for you.", result
    id, registered = emitter.registered.first
    assert_equal "c1", id
    assert_equal "pending", registered[:status]
    # the tool message is NOT added to the conversation until completion
    assert_empty chat.messages
    assert_equal 1, chat.asks
  end

  def test_executor_does_not_mark_pending_as_error
    tool = stub(name: "slow_tool")
    tool.stubs(:call).returns(Ask::Result.pending("Research started"))
    executor = Ask::Agent::ToolExecutor.new
    emitter = RecordingEmitter.new

    results = executor.execute(
      {"c1" => Ask::Agent::ToolCallInfo.new(id: "c1", name: "slow_tool", arguments: "{}")},
      [tool], hooks: @hooks, event_emitter: emitter
    )

    assert_equal 1, results.size
    assert_equal "pending", results.first[:status]
    assert_equal false, results.first[:result][:is_error]
    assert_equal "c1", results.first[:tool_call_id]
  end

  def test_session_completion_adds_tool_message_and_voices_follow_up
    chat = ScriptedChat.new(final_text: "We're open until five.")
    session = build_session(chat: chat, tool_result: Ask::Result.pending("Research started"))

    queue = Queue.new
    thread = Thread.new do
      session.run("What are your hours?")
      queue << :done
    end

    # Wait for the run to hand back with the interim reply, then complete
    # the pending tool from another thread (like a tool's background work).
    wait_for { session.instance_variable_get(:@pending_tools).any? }
    completed = session.complete_pending_tool(
      tool_call_id: "c1",
      result: {message: '{"hours": "9-5"}', is_error: false, tool_name: "slow_tool"}
    )
    assert completed

    thread.join(10)
    assert queue.pop(true), "run should finish"

    # the tool message landed in the conversation, keyed to the original call
    tool_msg = chat.messages.find { |m| m[:tool_call_id] == "c1" }
    assert_equal '{"hours": "9-5"}', tool_msg[:content]
    # the follow-up turn voiced the answer
    assert_equal 2, chat.asks
  end

  def test_completion_during_a_run_follows_up_after_the_turn
    chat = ScriptedChat.new
    session = build_session(chat: chat, tool_result: Ask::Result.pending("Working"))

    queue = Queue.new
    thread = Thread.new do
      session.run("First question")
      queue << :first_done
    end
    wait_for { session.instance_variable_get(:@pending_tools).any? }

    completed = session.complete_pending_tool(
      tool_call_id: "c1", result: {message: "done", is_error: false, tool_name: "slow_tool"}
    )
    assert completed

    # the completion arrived while the first run was still going; the
    # follow-up fires after it ends
    assert queue.pop(true)
    wait_for { chat.asks >= 2 }
    assert_equal 2, chat.asks
    thread.join(5)
  end

  def test_completing_unknown_tool_call_returns_false
    session = build_session(chat: ScriptedChat.new, tool_result: Ask::Result.pending("x"))

    refute session.complete_pending_tool(tool_call_id: "nope", result: {message: "x"})
  end

  def test_current_session_and_tool_call_id_are_exposed_during_run
    seen = Queue.new
    tool = Class.new(Ask::Tool) do
      name "accessor_probe"
      description "probe"
      define_method(:execute) do |**|
        seen << [Ask::Agent.current_session&.class, Ask::Agent.current_tool_call_id]
        Ask::Result.success("ok")
      end
    end
    chat = ScriptedChat.new(tool_name: "accessor_probe")
    session = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [tool], system_prompt: "You are terse."
    )
    session.instance_variable_set(:@chat, chat)
    session.run("hi")

    session_class, call_id = seen.pop
    assert_equal Ask::Agent::Session, session_class
    assert_equal "c1", call_id
  end

  private

  def build_session(chat:, tool_result:)
    tool = stub(name: "slow_tool")
    tool.stubs(:call).returns(tool_result)
    session = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [tool], system_prompt: "You are a receptionist."
    )
    session.instance_variable_set(:@chat, chat)
    session
  end

  def wait_for(timeout: 5)
    deadline = Time.now + timeout
    loop do
      return if yield

      raise "condition not met within #{timeout}s" if Time.now > deadline

      sleep 0.02
    end
  end
end
