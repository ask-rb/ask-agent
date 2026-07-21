# frozen_string_literal: true

require_relative "test_helper"

class PromptCachingTest < Minitest::Test
  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "claude-sonnet-4", provider: "anthropic"))
  end

  def test_anthropic_build_request_without_caching_uses_string_system
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")

    payload = provider.send(:build_request,
      [{ role: :system, content: "You are helpful." }, { role: :user, content: "Hi" }],
      model: "claude-sonnet-4")

    assert_equal "You are helpful.", payload[:system]
    assert_instance_of String, payload[:system]
  end

  def test_anthropic_build_request_with_caching_uses_array_system
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")

    payload = provider.send(:build_request,
      [{ role: :system, content: "You are helpful." }, { role: :user, content: "Hi" }],
      model: "claude-sonnet-4",
      prompt_caching: true)

    assert_instance_of Array, payload[:system]
    assert_equal "text", payload[:system][0][:type]
    assert_equal "You are helpful.", payload[:system][0][:text]
    assert_equal "ephemeral", payload[:system][0][:cache_control][:type]
  end

  def test_anthropic_build_request_with_caching_marks_last_user_message
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")

    payload = provider.send(:build_request,
      [{ role: :system, content: "Be helpful." },
       { role: :user, content: "First message" },
       { role: :assistant, content: "Sure" },
       { role: :user, content: "Second message" }],
      model: "claude-sonnet-4",
      prompt_caching: true)

    # Find the last user message
    user_messages = payload[:messages].select { |m| m[:role] == "user" }
    last_user = user_messages.last

    assert_instance_of Array, last_user[:content]
    content_item = last_user[:content].first
    assert_equal "ephemeral", content_item[:cache_control][:type]
  end

  def test_anthropic_build_request_no_user_messages_with_caching
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")

    payload = provider.send(:build_request,
      [{ role: :system, content: "Be helpful." }],
      model: "claude-sonnet-4",
      prompt_caching: true)

    # Should not crash even without user messages
    assert_instance_of Array, payload[:system]
    assert payload[:messages].empty?
  end

  def test_anthropic_parse_response_includes_cache_tokens
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")

    body = {
      "content" => [{ "type" => "text", "text" => "Hello!" }],
      "model" => "claude-sonnet-4",
      "usage" => {
        "input_tokens" => 150,
        "output_tokens" => 10,
        "cache_creation_input_tokens" => 100,
        "cache_read_input_tokens" => 50
      }
    }

    msg = provider.send(:parse_response, body, "claude-sonnet-4")
    assert_equal 150, msg.metadata[:input_tokens]
    assert_equal 10, msg.metadata[:output_tokens]
    assert_equal 100, msg.metadata[:cache_creation_input_tokens]
    assert_equal 50, msg.metadata[:cache_read_input_tokens]
  end

  def test_anthropic_parse_response_without_cache_tokens
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")

    body = {
      "content" => [{ "type" => "text", "text" => "Hello!" }],
      "model" => "claude-sonnet-4",
      "usage" => { "input_tokens" => 150, "output_tokens" => 10 }
    }

    msg = provider.send(:parse_response, body, "claude-sonnet-4")
    assert_nil msg.metadata[:cache_creation_input_tokens]
    assert_nil msg.metadata[:cache_read_input_tokens]
  end

  def test_openai_parse_response_includes_cached_tokens
    provider = Ask::Providers::OpenAI.new(api_key: "test-key")

    body = {
      "choices" => [{
        "message" => { "content" => "Hello!", "role" => "assistant" },
        "finish_reason" => "stop"
      }],
      "model" => "gpt-4o",
      "usage" => {
        "prompt_tokens" => 200,
        "completion_tokens" => 10,
        "prompt_tokens_details" => { "cached_tokens" => 150 }
      }
    }

    msg = provider.send(:parse_response, body, "gpt-4o")
    assert_equal 200, msg.metadata[:input_tokens]
    assert_equal 150, msg.metadata[:cached_tokens]
  end

  def test_openai_parse_response_without_cached_tokens
    provider = Ask::Providers::OpenAI.new(api_key: "test-key")

    body = {
      "choices" => [{
        "message" => { "content" => "Hello!", "role" => "assistant" },
        "finish_reason" => "stop"
      }],
      "model" => "gpt-4o",
      "usage" => { "prompt_tokens" => 200, "completion_tokens" => 10 }
    }

    msg = provider.send(:parse_response, body, "gpt-4o")
    assert_nil msg.metadata[:cached_tokens]
  end

  def test_chat_passes_prompt_caching_to_provider
    provider = Ask::Providers::OpenAI.new(api_key: "test-key")

    # Use a test chat with caching enabled
    chat = Ask::Agent::Chat.new(model: "gpt-4o", prompt_caching: true)
    req = chat.send(:build_request, false)

    assert req[:extra_params][:prompt_caching]
  end

  def test_chat_without_prompt_caching
    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    req = chat.send(:build_request, false)

    assert_nil req[:extra_params][:prompt_caching]
  end

  def test_global_config_prompt_caching
    Ask::Agent.configuration.prompt_caching = true
    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    req = chat.send(:build_request, false)

    assert req[:extra_params][:prompt_caching]
  ensure
    Ask::Agent.configuration.prompt_caching = false
  end

  def test_session_passes_prompt_caching
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))

    session = Ask::Agent::Session.new(model: "gpt-4o", prompt_caching: true)
    chat = session.instance_variable_get(:@chat)

    assert chat.instance_variable_get(:@prompt_caching)
  end

  def test_prompt_caching_capability_on_anthropic
    caps = Ask::Providers::Anthropic.capabilities
    assert caps[:prompt_caching]
  end

  def test_prompt_caching_capability_on_openai
    caps = Ask::Providers::OpenAI.capabilities
    assert caps[:prompt_caching]
  end

  def test_anthropic_has_prompt_caching_in_capabilities
    provider = Ask::Providers::Anthropic.new(api_key: "test-key")
    assert provider.class.capabilities[:prompt_caching]
  end
end
