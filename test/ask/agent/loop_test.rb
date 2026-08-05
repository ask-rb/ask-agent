# frozen_string_literal: true

require_relative "../../test_helper"

class LoopTest < Minitest::Test
  def setup
    @loop = Ask::Agent::Loop.new(max_turns: 5)
  end

  def test_initial_turn_count
    assert_equal 0, @loop.turn_count
  end

  def test_reset
    @loop.instance_variable_set(:@turn_count, 3)
    @loop.reset!
    assert_equal 0, @loop.turn_count
  end

  def test_run_turn_block_handles_nil_tool_calls
    # Simulate what the loop block does with chunk.tool_calls
    # when tool_calls is nil (should not crash)
    event_emitter = Object.new
    event_emitter.define_singleton_method(:emit) { |_| }

    chunk = Ask::Agent::ChatChunk.new(content: "Hello", tool_calls: nil, thinking: nil, input_tokens: nil, output_tokens: nil)
    refute chunk.tool_call?
  end

  def test_run_turn_block_handles_non_enumerable_tool_calls
    event_emitter = Object.new
    event_emitter.define_singleton_method(:emit) { |_| }

    # ChatChunk should always have Hash tool_calls, but verify guard works
    chunk = Ask::Agent::ChatChunk.new(content: "", tool_calls: {}, thinking: nil, input_tokens: nil, output_tokens: nil)
    refute chunk.tool_call?
  end
end

class LoopAbortTest < Minitest::Test
  class AbortableEmitter
    attr_accessor :aborted

    def initialize(aborted: false)
      @aborted = aborted
    end

    def abort_requested?
      @aborted
    end

    def emit(*) = nil
  end

  # Scripted chat: returns a tool-call response; flags the emitter as
  # aborted from the second ask on, so recursion stops after one tool turn.
  class ScriptedChat
    attr_reader :asks

    def initialize(emitter)
      @emitter = emitter
      @asks = 0
    end

    def add_message(*) = nil

    def ask(_message)
      @asks += 1
      @emitter.aborted = true if @asks > 1
      Ask::Agent::ResponseMessage.new(
        content: "hello", tool_calls: {"c1" => Ask::Agent::ToolCallInfo.new(id: "c1", name: "test_tool", arguments: "{}")},
        tool_results: {}, thinking: nil, input_tokens: 1, output_tokens: 1, cost: 0.0
      )
    end
  end

  def setup
    @loop = Ask::Agent::Loop.new(max_turns: 5)
    @hooks = Ask::Agent::Hooks.new({})
  end

  def test_aborted_run_skips_tool_execution_entirely
    chat = stub(add_message: nil)
    chat.stubs(:ask).returns(
      Ask::Agent::ResponseMessage.new(
        content: "hello", tool_calls: {"c1" => Ask::Agent::ToolCallInfo.new(id: "c1", name: "test_tool", arguments: "{}")},
        tool_results: {}, thinking: nil, input_tokens: 1, output_tokens: 1, cost: 0.0
      )
    )
    executor = stub
    executor.expects(:execute).never
    emitter = AbortableEmitter.new(aborted: true)

    result = @loop.run_turn(chat: chat, message: "hi", tools: [], tool_executor: executor,
                            compactor: nil, hooks: @hooks, event_emitter: emitter)

    assert_equal "hello", result
    assert_equal 1, @loop.turn_count
  end

  def test_abort_during_tool_turn_stops_recursion
    emitter = AbortableEmitter.new
    chat = ScriptedChat.new(emitter)
    executor = stub
    executor.stubs(:execute).returns([{tool_name: "test_tool", message: "ok", status: "success"}])

    result = @loop.run_turn(chat: chat, message: "hi", tools: [], tool_executor: executor,
                            compactor: nil, hooks: @hooks, event_emitter: emitter)

    assert_equal "hello", result
    # tools ran once, but the follow-up LLM call was skipped
    assert_equal 2, chat.asks
    assert_equal 2, @loop.turn_count
  end

  def test_plain_emitter_is_never_considered_aborted
    chat = stub(ask: Ask::Agent::ResponseMessage.new(
      content: "done", tool_calls: {}, tool_results: {}, thinking: nil,
      input_tokens: 1, output_tokens: 1, cost: 0.0
    ))
    executor = stub
    emitter = Object.new
    emitter.define_singleton_method(:emit) { |_| }

    result = @loop.run_turn(chat: chat, message: "hi", tools: [], tool_executor: executor,
                            compactor: nil, hooks: @hooks, event_emitter: emitter)

    assert_equal "done", result
  end
end
