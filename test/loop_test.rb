# frozen_string_literal: true

require_relative "test_helper"

class LoopTest < Minitest::Test
  include AgentTestHelpers

  def setup
    @loop = Ask::Agent::Loop.new(max_turns: 25)
  end

  def test_initialization
    assert_equal 0, @loop.turn_count
  end

  def test_custom_max_turns
    loop = Ask::Agent::Loop.new(max_turns: 5)
    5.times do |i|
      result = loop.run_turn(
        chat: build_chat(returns_text: true),
        message: "turn #{i}",
        tools: [],
        tool_executor: build_executor,
        compactor: nil,
        hooks: Ask::Agent::Hooks.new,
        event_emitter: build_emitter
      )
      assert_instance_of String, result
    end
  end

  def test_exceeds_max_turns
    loop = Ask::Agent::Loop.new(max_turns: 1)
    loop.run_turn(
      chat: build_chat(returns_text: true),
      message: "only turn",
      tools: [],
      tool_executor: build_executor,
      compactor: nil,
      hooks: Ask::Agent::Hooks.new,
      event_emitter: build_emitter
    )
    assert_raises(Ask::Agent::MaxTurnsExceeded) do
      loop.run_turn(
        chat: build_chat(returns_text: true),
        message: "should fail",
        tools: [],
        tool_executor: build_executor,
        compactor: nil,
        hooks: Ask::Agent::Hooks.new,
        event_emitter: build_emitter
      )
    end
  end

  def test_reset_clears_turn_count
    loop = Ask::Agent::Loop.new(max_turns: 1)
    assert_equal 0, loop.turn_count
    loop.reset!
    assert_equal 0, loop.turn_count
  end

  def test_loop_detection
    loop = Ask::Agent::Loop.new(max_turns: 25)
    results = [
      { tool_name: "get_weather", message: "Sunny" },
      { tool_name: "get_weather", message: "Sunny" },
      { tool_name: "get_weather", message: "Sunny" }
    ]

    refute loop.send(:loop_detected?, [results[0]])
    refute loop.send(:loop_detected?, [results[1]])
    assert loop.send(:loop_detected?, [results[2]])
  end

  def test_loop_detection_different_results
    loop = Ask::Agent::Loop.new(max_turns: 25)
    refute loop.send(:loop_detected?, [{ tool_name: "get_weather", message: "Sunny" }])
    refute loop.send(:loop_detected?, [{ tool_name: "get_time", message: "12:00" }])
    refute loop.send(:loop_detected?, [{ tool_name: "get_weather", message: "Rainy" }])
  end

  def test_default_max_consecutive_tool_turns
    loop = Ask::Agent::Loop.new(max_turns: 25, max_consecutive_tool_turns: 6)
    assert_equal 6, loop.instance_variable_get(:@max_consecutive_tool_turns)
  end

  def test_loop_detection_window
    assert_equal 3, Ask::Agent::Loop::LOOP_DETECTION_WINDOW
  end

  def test_non_tool_response_returns_content
    result = @loop.run_turn(
      chat: build_chat(returns_text: true),
      message: "hello",
      tools: [],
      tool_executor: build_executor,
      compactor: nil,
      hooks: Ask::Agent::Hooks.new,
      event_emitter: build_emitter
    )
    assert_equal "Mock response", result
  end

  def test_tool_response_executes_tools
    result = @loop.run_turn(
      chat: build_chat(returns_text: false, tool_call: true),
      message: "do something",
      tools: [],
      tool_executor: build_executor,
      compactor: nil,
      hooks: Ask::Agent::Hooks.new,
      event_emitter: build_emitter
    )
    assert_instance_of String, result
  end

  def test_turn_count_increments
    assert_equal 0, @loop.turn_count
    @loop.run_turn(
      chat: build_chat(returns_text: true),
      message: "test",
      tools: [],
      tool_executor: build_executor,
      compactor: nil,
      hooks: Ask::Agent::Hooks.new,
      event_emitter: build_emitter
    )
    assert_equal 1, @loop.turn_count
  end

  def test_consecutive_tool_turns_resets_on_text_response
    3.times do
      @loop.run_turn(
        chat: build_chat(returns_text: true),
        message: "test",
        tools: [],
        tool_executor: build_executor,
        compactor: nil,
        hooks: Ask::Agent::Hooks.new,
        event_emitter: build_emitter
      )
    end
    assert_equal 0, @loop.instance_variable_get(:@consecutive_tool_turns)
  end

  private

  def build_chat(returns_text: true, tool_call: false)
    chat = stub
    chat.stubs(:model).returns("gpt-4o")
    chat.stubs(:model_id).returns("gpt-4o")
    chat.stubs(:messages).returns([])

    if tool_call
      tool_calls = {
        "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "test_tool", arguments: "{}")
      }
      chat.stubs(:ask).yields(
        Ask::Agent::ChatChunk.new(content: "", tool_calls: tool_calls, thinking: nil)
      ).returns(
        Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, thinking: nil)
      )
    elsif returns_text
      chat.stubs(:ask).yields(
        Ask::Agent::ChatChunk.new(content: "Mock response", tool_calls: {}, thinking: nil)
      ).returns(
        Ask::Agent::ResponseMessage.new(content: "Mock response", tool_calls: {}, thinking: nil)
      )
    end

    chat.stubs(:add_message)
    chat
  end

  def build_executor
    executor = stub
    executor.stubs(:execute_parallel).returns([])
    executor.stubs(:execute).returns([])
    executor.stubs(:total_executions).returns(0)
    executor
  end

  def build_emitter
    emitter = stub
    emitter.stubs(:emit)
    emitter
  end
end
