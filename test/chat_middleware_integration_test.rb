# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/provider_stubs"

# Middleware class for tracking calls
$integration_test_log = []

class TestTrackingMiddleware < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    $integration_test_log << :before
    result = yield
    $integration_test_log << :after
    result
  end
end

# Middleware for injecting params
class TestInjectMiddleware < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    ep = request[:extra_params] || {}
    ep[:custom] = "injected"
    request[:extra_params] = ep
    yield
  end
end

# Transform for filtering chunks
class TestFilterTransform < Ask::Agent::StreamTransforms::Base
  def call(chunk, &block)
    block.call(chunk) unless chunk.content == "filter_me"
  end
end

class ChatMiddlewareIntegrationTest < Minitest::Test
  include ProviderStubs

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "claude-sonnet-4", provider: "anthropic"))

    # Reset middleware/transform config for each test
    @original_middleware = Ask::Agent.configuration.middleware
    Ask::Agent.configuration.instance_variable_set(:@middleware, Ask::Agent::Middleware::Pipeline.new)
    @original_transforms = Ask::Agent.configuration.stream_transforms
    Ask::Agent.configuration.instance_variable_set(:@stream_transforms, Ask::Agent::StreamTransforms::Pipeline.new)
  end

  def teardown
    Ask::Agent.configuration.instance_variable_set(:@middleware, @original_middleware)
    Ask::Agent.configuration.instance_variable_set(:@stream_transforms, @original_transforms)
  end

  def test_chat_uses_middleware_pipeline
    $integration_test_log.clear
    Ask::Agent.configure do |c|
      c.middleware.use TestTrackingMiddleware
    end

    with_fake_chat("gpt-4o") do |chat|
      chat.ask("Hello")
    end

    assert_equal [:before, :after], $integration_test_log
  end

  def test_middleware_can_log_and_modify
    Ask::Agent.configure do |c|
      c.middleware.use TestInjectMiddleware
    end

    with_fake_chat("gpt-4o") do |chat|
      response = chat.ask("Hello")
      assert response.content
    end
  end

  def test_chat_without_middleware_still_works
    with_fake_chat("gpt-4o") do |chat|
      response = chat.ask("Hello")
      assert_equal "Echo: Hello", response.content
    end
  end

  def test_stream_transforms_integration
    Ask::Agent.configure do |c|
      c.stream_transforms.use TestFilterTransform
    end

    with_streaming_chat("gpt-4o", chunks: ["Hello ", "filter_me", "World"]) do |chat|
      chunks = []
      chat.ask("Hello") { |chunk| chunks << chunk }
      contents = chunks.map(&:content).compact
      assert_equal ["Hello ", "World"], contents
    end
  end

  def test_thinking_separator_via_config
    Ask::Agent.configure do |c|
      c.stream_transforms.use :thinking_separator
    end

    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    stub_chat_provider(chat, build_streaming_provider_with_thinking)

    thinking_chunks = []
    text_chunks = []
    chat.ask("Hello") { |chunk|
      text_chunks << chunk.content if chunk.content&.length&.> 0
      thinking_chunks << chunk.thinking if chunk.thinking&.length&.> 0
    }

    assert thinking_chunks.any?, "Should have extracted thinking chunks"
    assert text_chunks.any?, "Should have text chunks"
  end

  def test_middleware_and_transforms_together
    $integration_test_log.clear
    Ask::Agent.configure do |c|
      c.middleware.use TestTrackingMiddleware
      c.stream_transforms.use TestFilterTransform
    end

    with_streaming_chat("gpt-4o", chunks: ["Hi ", "filter_me", "there"]) do |chat|
      chunks = []
      chat.ask("Hello") { |chunk| chunks << chunk }
      assert_equal [:before, :after], $integration_test_log
      assert_equal ["Hi ", "there"], chunks.map(&:content).compact
    end
  end

  def test_retry_middleware_via_config
    Ask::Agent.configure do |c|
      c.middleware.use :retry_on_failure, max_retries: 2
    end

    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    call_count = 0
    error_provider = Object.new
    error_provider.define_singleton_method(:chat) do |*args, model:, **kwargs, &block|
      call_count += 1
      raise Ask::RateLimitError, "limit" if call_count < 2
      Ask::Message.new(role: :assistant, content: "ok")
    end
    chat.define_singleton_method(:build_provider) { error_provider }
    chat.instance_variable_set(:@provider, nil)

    response = chat.ask("Hello")
    assert_equal "ok", response.content
    assert_equal 2, call_count
  end

  private

  def with_fake_chat(model, tool_calls: nil)
    chat = Ask::Agent::Chat.new(model: model)
    stub_chat_provider(chat, build_fake_provider(tool_calls: tool_calls))
    yield chat
  end

  def with_streaming_chat(model, chunks: ["Hello ", "World"])
    chat = Ask::Agent::Chat.new(model: model)
    stub_chat_provider(chat, build_streaming_provider(chunks: chunks))
    yield chat
  end

  def build_streaming_provider_with_thinking
    chunk1 = Ask::Chunk.new(content: "Visible text", thinking: "Hidden reasoning")
    chunk2 = Ask::Chunk.new(content: " more")

    provider = Object.new
    provider.define_singleton_method(:chat) do |*args, model:, **options, &block|
      stream = Ask::Stream.new
      [chunk1, chunk2].each do |c|
        stream.add(c)
        block.call(c) if block
      end
      stream.finish!
      stream
    end
    provider
  end
end
