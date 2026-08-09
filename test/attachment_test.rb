# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/provider_stubs"

# First-class attachments: add_message/ask with attachments, the modality
# gate, session threading, and persistence round-trips.
class AttachmentTest < Minitest::Test
  include ProviderStubs

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    @chat = Ask::Agent::Chat.new(model: "gpt-4o")
  end

  def attachment(data: "file content", filename: "notes.txt", mime_type: "text/plain", **rest)
    Ask::Attachment.new(data: data, filename: filename, mime_type: mime_type, **rest)
  end

  # --- add_message / ask ---

  def test_add_message_merges_attachments_into_content_blocks
    @chat.add_message(role: :user, content: "Read this", attachments: [attachment])

    message = @chat.messages.last
    assert message.multimodal?
    assert_equal 2, message.content_blocks.size
    assert_instance_of Ask::Content::Text, message.content_blocks[0]
    assert_equal "Read this", message.content_blocks[0].text
    assert_instance_of Ask::Content::File, message.content_blocks[1]
    assert_equal "notes.txt", message.content_blocks[1].filename
  end

  def test_add_message_without_content_but_with_attachments
    @chat.add_message(role: :user, attachments: [attachment])

    message = @chat.messages.last
    assert_equal 1, message.content_blocks.size
    assert_instance_of Ask::Content::File, message.content_blocks[0]
  end

  def test_ask_with_attachments_builds_a_multimodal_message
    stub_chat_provider(@chat)
    @chat.ask("What's in the file?", attachments: [attachment])

    message = @chat.messages.first
    assert message.multimodal?
    assert_equal ["text", "file"], message.content_blocks.map { |b| b.to_h[:type] }
  end

  def test_context_attachments_render_a_manifest_text_block
    @chat.add_message(role: :user, content: "Noted", attachments: [attachment(delivery: :context)])

    message = @chat.messages.last
    refute message.multimodal?
    assert_equal 2, message.content_blocks.size
    assert message.content_blocks.all? { |b| b.is_a?(Ask::Content::Text) }
    manifest = message.content_blocks.find { |b| b.text.include?("Attached file") }
    assert_includes manifest.text, "[Attached file: notes.txt"
    assert_includes manifest.text, "text/plain"
  end

  # --- Modality gate ---

  def test_raises_when_the_model_cannot_receive_the_attachment_type
    Ask::ModelCatalog.instance.register(
      Ask::ModelInfo.new(id: "text-only-model", provider: "openai", modalities: { input: %w[text] })
    )
    chat = Ask::Agent::Chat.new(model: "text-only-model")

    error = assert_raises(Ask::Agent::UnsupportedAttachmentError) do
      chat.add_message(role: :user, content: "Read this",
        attachments: [attachment(data: "%PDF-1.7", filename: "doc.pdf", mime_type: "application/pdf")])
    end
    assert_includes error.message, "pdf"
    assert_includes error.message, "text"
  end

  def test_passes_when_the_model_supports_the_attachment_type
    Ask::ModelCatalog.instance.register(
      Ask::ModelInfo.new(id: "vision-model", provider: "openai", modalities: { input: %w[text image] })
    )
    chat = Ask::Agent::Chat.new(model: "vision-model")

    chat.add_message(role: :user, content: "Read this",
      attachments: [attachment(data: "image", filename: "photo.png", mime_type: "image/png")])

    assert chat.messages.last.multimodal?
  end

  def test_context_attachments_skip_the_modality_gate
    Ask::ModelCatalog.instance.register(
      Ask::ModelInfo.new(id: "text-only-model-2", provider: "openai", modalities: { input: %w[text] })
    )
    chat = Ask::Agent::Chat.new(model: "text-only-model-2")

    chat.add_message(role: :user, content: "Noted",
      attachments: [attachment(data: "%PDF-1.7", filename: "doc.pdf", mime_type: "application/pdf", delivery: :context)])

    refute chat.messages.last.multimodal?
  end

  def test_gate_is_skipped_when_the_catalog_has_no_modality_info
    # "gpt-4o" was registered without modalities in setup
    @chat.add_message(role: :user, content: "Read this",
      attachments: [attachment(data: "%PDF-1.7", filename: "doc.pdf", mime_type: "application/pdf")])
    assert @chat.messages.last.multimodal?
  end

  # --- Session threading ---

  def test_session_run_threads_attachments_to_the_chat
    chat = Object.new
    chat.define_singleton_method(:model) { "gpt-4o" }
    chat.define_singleton_method(:model_id) { "gpt-4o" }
    chat.define_singleton_method(:messages) { [] }
    received = nil
    chat.define_singleton_method(:ask) do |message, attachments: nil, &block|
      received = attachments
      Ask::Agent::ResponseMessage.new(content: "ok", tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
    end
    chat.define_singleton_method(:add_message) { |**_kwargs| }

    session = Ask::Agent::Session.new(model: chat, tools: [])
    attachment = attachment(data: "x", filename: "a.txt", mime_type: "text/plain")
    session.run("hello", attachments: [attachment])

    assert_equal [attachment], received
  end

  def test_steer_with_attachments_when_idle
    chat = Object.new
    chat.define_singleton_method(:model) { "gpt-4o" }
    chat.define_singleton_method(:model_id) { "gpt-4o" }
    chat.define_singleton_method(:messages) { [] }
    chat.define_singleton_method(:ask) { |*_args, **_kwargs| Ask::Agent::ResponseMessage.new(content: "ok", tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil) }
    added = nil
    chat.define_singleton_method(:add_message) { |**_kwargs| added = _kwargs }

    session = Ask::Agent::Session.new(model: chat, tools: [])
    attachment = attachment(data: "x", filename: "a.txt", mime_type: "text/plain")
    result = session.steer("more", attachments: [attachment])

    assert_equal :steered, result[:status]
    assert_equal "more", added[:content]
    assert_equal [attachment], added[:attachments]
  end

  # --- Persistence ---

  def test_persistence_round_trips_content_blocks
    store = FakeStore.new
    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    stub_chat_provider(chat)
    chat.add_message(role: :user, content: "Read this", attachments: [attachment])

    session = Ask::Agent::Session.new(model: chat, tools: [], state: store)
    session.send(:persist!)

    restored = Ask::Agent::Session.load(session.id, adapter: store)
    refute_nil restored
    blocks = restored.chat.messages.first.content_blocks
    assert_equal 2, blocks.size
    assert_instance_of Ask::Content::Text, blocks[0]
    assert_instance_of Ask::Content::File, blocks[1]
    assert_equal "notes.txt", blocks[1].filename
    assert_equal "file content", blocks[1].data
  end

  class FakeStore
    def initialize
      @data = {}
    end

    def get(key) = @data[key]
    def set(key, value) = @data[key] = value
  end
end
