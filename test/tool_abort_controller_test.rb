# frozen_string_literal: true

require_relative "test_helper"

class ToolAbortControllerTest < Minitest::Test
  def setup
    @controller = Ask::Agent::ToolAbortController.new
  end

  def test_not_aborted_by_default
    refute @controller.aborted?
  end

  def test_abort_sets_flag
    @controller.abort!
    assert @controller.aborted?
  end

  def test_reset_clears_flag
    @controller.abort!
    @controller.reset!
    refute @controller.aborted?
  end

  def test_thread_safety
    threads = 10.times.map do
      Thread.new { 100.times { @controller.aborted? } }
    end
    threads.each(&:join)
    refute @controller.aborted?
  end
end
