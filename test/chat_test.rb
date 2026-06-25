# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/provider_stubs"

class ChatTest < Minitest::Test
  include ProviderStubs

  def setup
    @chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
  end

  def test_initialization
    assert_equal "gpt-4o", @chat.model_id
    assert_equal "gpt-4o", @chat.model
    assert_empty @chat.messages
  end

  def test_initialization_with_model_object
    obj = Object.new
    def obj.id; "claude-sonnet-4"; end
    chat = Ask::Agent::Chat.new(model: obj)
    assert_equal "claude-sonnet-4", chat.model_id
  end

  def test_initialization_with_provider_override
    chat = Ask::Agent::Chat.new(model: "gpt-4o", provider: "anthropic", assume_model_exists: true)
    assert_equal "gpt-4o", chat.model_id
  end

  def test_with_instructions_adds_system_prompt
    @chat.with_instructions("You are a helpful assistant.")
    assert_equal 1, @chat.messages.length
    assert_equal :system, @chat.messages.first.role
    assert_equal "You are a helpful assistant.", @chat.messages.first.content
  end

  def test_with_instructions_replaces_existing_prompt
    @chat.with_instructions("First prompt.")
    @chat.with_instructions("Second prompt.")
    assert_equal 1, @chat.messages.length
    assert_equal "Second prompt.", @chat.messages.first.content
  end

  def test_add_message_user
    @chat.add_message(role: :user, content: "Hello")
    assert_equal 1, @chat.messages.length
    assert_equal :user, @chat.messages.first.role
    assert_equal "Hello", @chat.messages.first.content
  end

  def test_add_message_with_tool_results
    @chat.add_message(role: :tool, content: "42", tool_call_id: "call_1")
    assert_equal 1, @chat.messages.length
    assert_equal :tool, @chat.messages.first.role
  end

  def test_add_message_with_tool_calls
    calls = [{ id: "call_abc", type: "function", name: "get_weather", arguments: '{"city":"London"}' }]
    @chat.add_message(role: :assistant, content: nil, tool_calls: calls)
    msg = @chat.messages.first
    assert_equal :assistant, msg.role
    assert_equal calls, msg.tool_calls
  end

  def test_reset_messages
    @chat.add_message(role: :user, content: "Hello")
    @chat.reset_messages!
    assert_empty @chat.messages
  end

  def test_with_schema
    schema = { type: "object", properties: { answer: { type: "string" } } }
    @chat.with_schema(schema)
    assert @chat.instance_variable_get(:@schema)
  end

  def test_with_params
    @chat.with_params(temperature: 0.7, max_tokens: 100)
    extra = @chat.instance_variable_get(:@extra_params)
    assert_equal 0.7, extra[:temperature]
    assert_equal 100, extra[:max_tokens]
  end

  def test_with_params_merges
    @chat.with_params(temperature: 0.5)
    @chat.with_params(max_tokens: 200)
    extra = @chat.instance_variable_get(:@extra_params)
    assert_equal 0.5, extra[:temperature]
    assert_equal 200, extra[:max_tokens]
  end

  def test_ask_adds_user_message
    with_fake_chat("gpt-4o") do |chat|
      chat.ask("Hello")
      user_msgs = chat.messages.select { |m| m.role == :user }
      assert_equal 1, user_msgs.length
      assert_equal "Hello", user_msgs.first.content
    end
  end

  def test_ask_returns_response_message
    with_fake_chat("gpt-4o") do |chat|
      response = chat.ask("Hello")
      assert_instance_of Ask::Agent::ResponseMessage, response
    end
  end

  def test_ask_stores_assistant_message
    with_fake_chat("gpt-4o") do |chat|
      chat.ask("Hello")
      assistant_msgs = chat.messages.select { |m| m.role == :assistant }
      assert_equal 1, assistant_msgs.length
    end
  end

  def test_conversation_history_preserved
    with_fake_chat("gpt-4o") do |chat|
      chat.ask("First")
      chat.ask("Second")
      assert_equal 4, chat.messages.length
    end
  end

  def test_chat_round_trip
    with_fake_chat("gpt-4o") do |chat|
      chat.add_message(role: :system, content: "Be helpful")
      response = chat.ask("Hi")
      assert_instance_of Ask::Agent::ResponseMessage, response
      assert_equal 3, chat.messages.length
    end
  end

  def test_ask_with_streaming
    with_streaming_chat("gpt-4o") do |chat|
      chunks = []
      response = chat.ask("Hello") { |chunk| chunks << chunk }
      assert_instance_of Ask::Agent::ResponseMessage, response
      assert chunks.any?
      assert chunks.all? { |c| c.is_a?(Ask::Agent::ChatChunk) }
    end
  end

  def test_streaming_accumulates_content
    with_streaming_chat("gpt-4o") do |chat|
      chunks = []
      response = chat.ask("Hello") { |chunk| chunks << chunk }
      assert_equal "Hello World", response.content
    end
  end

  def test_ask_with_tool_calls
    tool_calls = [{ id: "call_1", type: "function", name: "get_weather", arguments: '{"city":"London"}' }]
    with_fake_chat("gpt-4o", tool_calls: tool_calls) do |chat|
      response = chat.ask("Weather?")
      assert response.tool_call?
      assert response.tool_calls.key?("call_1")
      assert_equal "get_weather", response.tool_calls["call_1"].name
    end
  end

  def test_ask_stores_tool_calls_in_history
    tool_calls = [{ id: "call_1", type: "function", name: "get_weather", arguments: '{"city":"London"}' }]
    with_fake_chat("gpt-4o", tool_calls: tool_calls) do |chat|
      chat.ask("Weather?")
      msg = chat.messages.find { |m| m.role == :assistant }
      assert msg.tool_calls.is_a?(Array)
      assert_equal "get_weather", msg.tool_calls.first[:name]
    end
  end

  def test_with_instructions_returns_self
    result = @chat.with_instructions("Be good.")
    assert_same @chat, result
  end

  def test_with_schema_returns_self
    result = @chat.with_schema({ type: "object" })
    assert_same @chat, result
  end

  def test_with_params_returns_self
    result = @chat.with_params(temp: 0.5)
    assert_same @chat, result
  end

  def test_response_message_basics
    msg = Ask::Agent::ResponseMessage.new(content: "Hello", tool_calls: {}, thinking: nil)
    assert_equal "Hello", msg.content
    refute msg.tool_call?
    assert_equal "Hello", msg.to_s
  end

  def test_response_message_with_tool_calls
    tc = { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "get_weather", arguments: '{"city":"London"}') }
    msg = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tc, thinking: nil)
    assert msg.tool_call?
  end

  def test_chat_chunk_basics
    chunk = Ask::Agent::ChatChunk.new(content: "Hello", tool_calls: {}, thinking: nil)
    assert_equal "Hello", chunk.content
    refute chunk.tool_call?
  end

  def test_chat_chunk_with_tool_calls
    tc = { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "get_weather", arguments: "") }
    chunk = Ask::Agent::ChatChunk.new(content: "", tool_calls: tc, thinking: nil)
    assert chunk.tool_call?
  end

  def test_tool_call_info
    info = Ask::Agent::ToolCallInfo.new(id: "call_1", name: "get_weather", arguments: '{"city":"London"}')
    assert_equal "call_1", info.id
    assert_equal "get_weather", info.name
    assert_equal '{"city":"London"}', info.arguments
  end

  def test_chunk_thinking
    chunk = Ask::Agent::ChatChunk.new(content: "Visible", tool_calls: {}, thinking: "Hidden reasoning")
    assert_equal "Hidden reasoning", chunk.thinking
  end

  def test_response_message_thinking
    msg = Ask::Agent::ResponseMessage.new(content: "Visible", tool_calls: {}, thinking: "Hidden")
    assert_equal "Hidden", msg.thinking
  end

  def test_messages_private_dup
    msgs = @chat.messages
    msgs << :oops
    assert_equal 1, @chat.messages.length
  end

  private

  def with_fake_chat(model, tool_calls: nil)
    chat = Ask::Agent::Chat.new(model: model, assume_model_exists: true)
    stub_chat_provider(chat, build_fake_provider(tool_calls: tool_calls))
    yield chat
  end

  def with_streaming_chat(model)
    chat = Ask::Agent::Chat.new(model: model, assume_model_exists: true)
    stub_chat_provider(chat, build_streaming_provider)
    yield chat
  end
end
