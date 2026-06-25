# frozen_string_literal: true

module ProviderStubs
  # Build a fake provider that echoes messages back
  def build_fake_provider(prefix: "Echo: ", tool_calls: nil)
    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **options, &block|
      last = messages.respond_to?(:last) ? messages.last : messages
      last_content = last.is_a?(Hash) ? (last[:content] || "") : last.to_s
      Ask::Message.new(role: :assistant, content: tool_calls ? "" : "#{prefix}#{last_content}", tool_calls: tool_calls)
    end
    provider
  end

  # Build a streaming provider
  def build_streaming_provider(chunks: ["Hello ", "World"])
    stream = Ask::Stream.new
    chunks.each { |c| stream.add(Ask::Chunk.new(content: c)) }
    stream.finish!

    provider = Object.new
    provider.define_singleton_method(:chat) do |messages, model:, **options, &block|
      chunks.each { |c| block&.call(Ask::Chunk.new(content: c)) }
      stream
    end
    provider
  end

  # Stub a chat instance's provider
  def stub_chat_provider(chat, provider = build_fake_provider)
    chat.define_singleton_method(:build_provider) { provider }
    chat.instance_variable_set(:@provider, nil)
  end
end
