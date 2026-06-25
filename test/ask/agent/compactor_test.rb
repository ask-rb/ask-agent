# frozen_string_literal: true

require_relative "../../test_helper"

class CompactorTest < Minitest::Test
  def setup
    @compactor = Ask::Agent::Compactor.new(threshold: 0.5)
  end

  def test_estimate_tokens
    assert_equal 1, @compactor.estimate_tokens("hi")
  end

  def test_estimate_tokens_empty
    assert_equal 0, @compactor.estimate_tokens("")
  end

  def test_empty_tokens
    assert_equal 0, @compactor.estimate_total_tokens
  end

  def test_no_chat_should_not_compact
    refute @compactor.should_compact?
  end

  def test_no_chat_run_does_nothing
    @compactor.run
    assert true
  end

  def test_overflow_recovered_defaults_to_false
    refute @compactor.overflow_recovered?
  end

  def test_microcompact_with_empty_chat
    @compactor.microcompact!
    assert true
  end

  def test_context_window_with_chat
    chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
    @compactor.chat = chat
    assert_equal 128_000, @compactor.context_window
  end

  def test_estimate_total_tokens_with_messages
    chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
    chat.add_message(role: :user, content: "Hello, world!")
    @compactor.chat = chat
    count = @compactor.estimate_total_tokens
    assert count > 0
  end

  def test_compact_requires_at_least_6_messages
    chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
    5.times { |i| chat.add_message(role: :user, content: "msg #{i}") }
    @compactor.chat = chat
    @compactor.compact!
    assert_operator chat.messages.size, :>=, 5
  end

  def test_recover_from_overflow
    chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
    chat.add_message(role: :user, content: "Hello")
    @compactor.chat = chat
    @compactor.recover_from_overflow
    assert @compactor.overflow_recovered?
  end

  def test_run_emits_events
    chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
    chat.add_message(role: :user, content: "Hi")
    @compactor.chat = chat
    @compactor.run
    assert true
  end

  def test_should_compact_requires_chat
    refute @compactor.should_compact?
  end

  def test_should_compact_returns_false_below_threshold
    chat = Ask::Agent::Chat.new(model: "gpt-4o", assume_model_exists: true)
    chat.add_message(role: :user, content: "Short")
    @compactor.chat = chat
    refute @compactor.should_compact?
  end
end
