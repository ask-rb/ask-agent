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
end
