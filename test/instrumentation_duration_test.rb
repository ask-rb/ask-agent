# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/provider_stubs"
require "ask/instrumentation"

# The chat.ask event must measure the real LLM call: before the fix, the
# event was emitted after the call without a block, so event.duration was
# ~0ms and ask_llm_duration_seconds was meaningless.
class InstrumentationDurationTest < Minitest::Test
  include ProviderStubs

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
  end

  def test_chat_ask_event_duration_measures_llm_call
    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **, &block|
      sleep 0.05
      Ask::Message.new(role: :assistant, content: "Echo")
    end
    events = []
    subscriber = Ask::Instrumentation.subscribe("chat.ask") { |e| events << e }

    with_chat(provider) { |chat| chat.ask("Hello") }

    assert_equal 1, events.length
    event = events.first
    assert_operator event.duration, :>=, 50.0, "event.duration should cover the LLM call"
    assert_equal "gpt-4o", event.payload[:model]
    assert_equal "openai", event.payload[:provider]
    assert_equal false, event.payload[:stream]
  ensure
    Ask::Instrumentation.unsubscribe(subscriber) if subscriber
  end

  def test_chat_stream_ask_event_duration_measures_stream
    events = []
    subscriber = Ask::Instrumentation.subscribe("chat.stream.ask") { |e| events << e }

    with_chat(build_streaming_provider) do |chat|
      chat.ask("Hello") { |_chunk| }
    end

    assert_equal 1, events.length
    event = events.first
    assert_operator event.duration, :>=, 0.0
    assert_equal true, event.payload[:stream]
  ensure
    Ask::Instrumentation.unsubscribe(subscriber) if subscriber
  end

  def test_event_payload_includes_tokens_and_tool_calls
    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **, &block|
      Ask::Message.new(
        role: :assistant,
        content: "",
        tool_calls: [{ id: "call_1", type: "function", name: "get_weather", arguments: '{"city":"London"}' }],
        metadata: { input_tokens: 100, output_tokens: 50 }
      )
    end
    events = []
    subscriber = Ask::Instrumentation.subscribe("chat.ask") { |e| events << e }

    with_chat(provider) { |chat| chat.ask("Weather?") }

    payload = events.first.payload
    usage = payload[:usage]
    assert_equal 100, usage[:input_tokens]
    assert_equal 50, usage[:output_tokens]
    assert_equal true, usage[:tool_calls]
  ensure
    Ask::Instrumentation.unsubscribe(subscriber) if subscriber
  end

  def test_broken_subscriber_does_not_break_ask
    subscriber = Ask::Instrumentation.subscribe("chat.ask") { |_e| raise "subscriber bug" }

    with_chat(build_fake_provider) do |chat|
      response = chat.ask("Hello")
      assert_instance_of Ask::Agent::ResponseMessage, response
      assert_equal "Echo: Hello", response.content
    end
  ensure
    Ask::Instrumentation.unsubscribe(subscriber) if subscriber
  end

  private

  def with_chat(provider)
    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    stub_chat_provider(chat, provider)
    yield chat
  end
end
