# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/provider_stubs"

class ChatTest < Minitest::Test
  include ProviderStubs

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "claude-sonnet-4", provider: "anthropic"))
    @chat = Ask::Agent::Chat.new(model: "gpt-4o")
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
    chat = Ask::Agent::Chat.new(model: "gpt-4o", provider: "anthropic")
    assert_equal "gpt-4o", chat.model_id
  end

  def test_default_provider_config_is_used_when_no_override
    previous = Ask::Agent.configuration.default_provider
    Ask::Agent.configuration.default_provider = :anthropic

    resolved = nil
    fake_class = Class.new do
      def initialize(config); end
    end

    Ask::Provider.stub(:resolve, ->(slug) { resolved = slug; fake_class }) do
      chat = Ask::Agent::Chat.new(model: "gpt-4o")
      chat.send(:provider)
    end

    assert_equal "anthropic", resolved.to_s
  ensure
    Ask::Agent.configuration.default_provider = previous
  end

  def test_per_chat_provider_override_wins_over_default
    previous = Ask::Agent.configuration.default_provider
    Ask::Agent.configuration.default_provider = :openai

    resolved = nil
    fake_class = Class.new do
      def initialize(config); end
    end

    Ask::Provider.stub(:resolve, ->(slug) { resolved = slug; fake_class }) do
      chat = Ask::Agent::Chat.new(model: "gpt-4o", provider: "anthropic")
      chat.send(:provider)
    end

    assert_equal "anthropic", resolved.to_s
  ensure
    Ask::Agent.configuration.default_provider = previous
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

  def test_ask_with_blank_message_does_not_add_empty_user_message
    stub_chat_provider(@chat)

    @chat.add_message(role: :user, content: "finalize")
    @chat.ask("")

    user_messages = @chat.messages.select { |m| m.role == :user }
    assert_equal 1, user_messages.length, 'ask("") must not append an empty user message'
  end

  def test_ask_with_whitespace_message_does_not_add_user_message
    stub_chat_provider(@chat)

    @chat.ask("   ")

    assert_empty @chat.messages.select { |m| m.role == :user }
  end

  def test_ask_with_real_message_adds_user_message
    stub_chat_provider(@chat)

    @chat.ask("Hello")

    user_messages = @chat.messages.select { |m| m.role == :user }
    assert_equal 1, user_messages.length
    assert_equal "Hello", user_messages.first.content
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

  def test_streaming_usage_counts_real_tokens
    # deepseek/OpenAI streams carry prompt_tokens/completion_tokens on the
    # final chunk; the old code read only input/output_tokens and reported
    # 0 in / ~1 out for every streamed call (and double-counted content
    # chunks on top).
    stream = Ask::Stream.new
    stream.add(Ask::Chunk.new(content: "Hello "))
    stream.add(Ask::Chunk.new(content: "World"))
    stream.add(Ask::Chunk.new(
      content: "", finish_reason: "stop",
      usage: {"prompt_tokens" => 12, "completion_tokens" => 5}
    ))
    stream.finish!
    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **options, &block|
      stream
    end

    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    stub_chat_provider(chat, provider)
    response = chat.ask("Hi") { |_chunk| }
    assert_equal 12, response.input_tokens
    assert_equal 5, response.output_tokens
  end

  def test_streaming_without_usage_falls_back_to_content_chunks
    stream = Ask::Stream.new
    stream.add(Ask::Chunk.new(content: "Hello "))
    stream.add(Ask::Chunk.new(content: "World"))
    stream.finish!
    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **options, &block|
      stream
    end

    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    stub_chat_provider(chat, provider)
    response = chat.ask("Hi") { |_chunk| }
    assert_equal 0, response.input_tokens
    assert_equal 2, response.output_tokens
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
    msg = Ask::Agent::ResponseMessage.new(content: "Hello", tool_calls: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
    assert_equal "Hello", msg.content
    refute msg.tool_call?
    assert_equal "Hello", msg.to_s
  end

  def test_response_message_with_tool_calls
    tc = { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "get_weather", arguments: '{"city":"London"}') }
    msg = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tc, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
    assert msg.tool_call?
  end

  def test_chat_chunk_basics
    chunk = Ask::Agent::ChatChunk.new(content: "Hello", tool_calls: {}, thinking: nil, input_tokens: nil, output_tokens: nil)
    assert_equal "Hello", chunk.content
    refute chunk.tool_call?
  end

  def test_chat_chunk_with_tool_calls
    tc = { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "get_weather", arguments: "") }
    chunk = Ask::Agent::ChatChunk.new(content: "", tool_calls: tc, thinking: nil, input_tokens: nil, output_tokens: nil)
    assert chunk.tool_call?
  end

  def test_tool_call_info
    info = Ask::Agent::ToolCallInfo.new(id: "call_1", name: "get_weather", arguments: '{"city":"London"}')
    assert_equal "call_1", info.id
    assert_equal "get_weather", info.name
    assert_equal '{"city":"London"}', info.arguments
  end

  def test_chunk_thinking
    chunk = Ask::Agent::ChatChunk.new(content: "Visible", tool_calls: {}, thinking: "Hidden reasoning", input_tokens: nil, output_tokens: nil)
    assert_equal "Hidden reasoning", chunk.thinking
  end

  def test_response_message_thinking
    msg = Ask::Agent::ResponseMessage.new(content: "Visible", tool_calls: {}, thinking: "Hidden", input_tokens: nil, output_tokens: nil, cost: nil)
    assert_equal "Hidden", msg.thinking
  end

  def test_messages_private_dup
    msgs = @chat.messages
    msgs << :oops
    assert_equal 1, @chat.messages.length
  end

  # --- Defensive nil/each guards ---

  # --- Defensive nil/each guards ---

  def test_accumulate_tool_calls_with_nil_does_not_crash
    calls_acc = {}
    chunk = Ask::Chunk.new(content: ",", tool_calls: nil)
    @chat.send(:accumulate_tool_calls, chunk, calls_acc)
    assert_empty calls_acc
  end

  def test_accumulate_tool_calls_with_empty_array_does_not_crash
    calls_acc = {}
    chunk = Ask::Chunk.new(content: ",", tool_calls: [])
    @chat.send(:accumulate_tool_calls, chunk, calls_acc)
    assert_empty calls_acc
  end

  def test_accumulate_tool_calls_normal_case
    calls_acc = {}
    chunk = Ask::Chunk.new(content: ",", tool_calls: [{ index: 0, id: "call_1", name: "get_weather", arguments: "{}" }])
    @chat.send(:accumulate_tool_calls, chunk, calls_acc)
    assert_equal "call_1", calls_acc.dig(0, :id)
    assert_equal "get_weather", calls_acc.dig(0, :name)
  end

  def test_build_tool_call_hash_with_nil_returns_empty_hash
    result = @chat.send(:build_tool_call_hash, nil)
    assert_equal({}, result)
  end

  def test_build_tool_call_hash_with_non_enumerable_returns_empty_hash
    result = @chat.send(:build_tool_call_hash, "not an array")
    assert_equal({}, result)
  end

  def test_build_tool_call_hash_with_valid_array
    raw = [{ id: "call_1", name: "get_weather", arguments: "{}" }]
    result = @chat.send(:build_tool_call_hash, raw)
    assert result.key?("call_1")
    assert_equal "get_weather", result["call_1"].name
  end

  def test_build_tool_call_hash_with_empty_array
    result = @chat.send(:build_tool_call_hash, [])
    assert_equal({}, result)
  end

  def test_build_tool_call_hash_with_array_of_malformed_entries
    # Provider returned tool_calls as an array, but entries are not all Hashes
    raw = [nil, "not-a-hash", { id: "call_1", name: "get_weather", arguments: "{}" }]
    result = @chat.send(:build_tool_call_hash, raw)
    assert_equal 1, result.size
    assert_equal "get_weather", result["call_1"].name
  end

  # Streaming with nil tool calls should not crash
  def test_streaming_with_nil_tool_calls_does_not_crash
    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **options, &block|
      block&.call(Ask::Chunk.new(content: "Hello", tool_calls: nil))
      block&.call(Ask::Chunk.new(content: " World", tool_calls: nil))
      stream = Ask::Stream.new
      stream.finish!
      stream
    end

    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    chat.define_singleton_method(:build_provider) { provider }

    chunks = []
    response = chat.ask("Hi") { |c| chunks << c }
    assert_instance_of Ask::Agent::ResponseMessage, response
    assert chunks.any?
  end

  private

  def with_fake_chat(model, tool_calls: nil)
    chat = Ask::Agent::Chat.new(model: model)
    stub_chat_provider(chat, build_fake_provider(tool_calls: tool_calls))
    yield chat
  end

  def with_streaming_chat(model)
    chat = Ask::Agent::Chat.new(model: model)
    stub_chat_provider(chat, build_streaming_provider)
    yield chat
  end
end
