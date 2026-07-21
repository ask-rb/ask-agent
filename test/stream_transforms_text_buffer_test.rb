# frozen_string_literal: true

require_relative "test_helper"

class StreamTransformsTextBufferTest < Minitest::Test
  def setup
    @transform = Ask::Agent::StreamTransforms::TextBuffer.new(min_size: 10)
  end

  def test_buffers_small_chunks
    results = []
    @transform.call(Ask::Chunk.new(content: "Hello ")) { |c| results << c }
    @transform.call(Ask::Chunk.new(content: "World")) { |c| results << c }

    # "Hello World" is 11 chars, >= min_size of 10, so it should emit
    assert_equal 1, results.length
    assert_equal "Hello World", results.first.content
  end

  def test_emits_when_buffer_reaches_min_size
    results = []
    # Each chunk is 5 chars, min_size is 10, so every 2 chunks emit
    @transform.call(Ask::Chunk.new(content: "AAAAA")) { |c| results << c }
    assert_equal 0, results.length, "Should buffer, not emit yet"

    @transform.call(Ask::Chunk.new(content: "BBBBB")) { |c| results << c }
    assert_equal 1, results.length, "Should emit after buffer >= min_size"
    assert_equal "AAAAABBBBB", results.first.content
  end

  def test_flush_emits_remaining_buffer
    @transform.call(Ask::Chunk.new(content: "Small")) { |c| }

    results = []
    @transform.finish { |c| results << c }
    assert_equal 1, results.length
    assert_equal "Small", results.first.content
  end

  def test_flush_with_empty_buffer_emits_nothing
    results = []
    @transform.finish { |c| results << c }
    assert_equal 0, results.length
  end

  def test_non_content_chunks_pass_through
    results = []
    @transform.call(Ask::Chunk.new(content: "Hello")) { |c| results << c }
    @transform.call(Ask::Chunk.new(content: nil, tool_calls: [{ id: "call_1" }])) { |c| results << c }

    # "Hello" is flushed before the non-content chunk, then the tool_calls chunk passes through
    assert_equal 2, results.length
    assert_equal "Hello", results[0].content
    refute results[0].tool_calls
    assert results[1].tool_calls
  end

  def test_passthrough_single_large_chunk
    results = []
    chunk = Ask::Chunk.new(content: "This is a very long text that exceeds the buffer")
    @transform.call(chunk) { |c| results << c }
    assert_equal 1, results.length
    assert_equal chunk.content, results.first.content
  end

  def test_buffer_clears_after_emitting
    @transform.call(Ask::Chunk.new(content: "1234567890")) { |c| }
    assert_equal "", @transform.instance_variable_get(:@buffer),
      "Buffer should be empty after emitting"
  end

  def test_finish_emits_pending_metadata
    @transform.call(Ask::Chunk.new(content: "hello", tool_calls: [])) { |c| }
    # Buffer has "hello", not yet emitted
    results = []
    @transform.finish { |c| results << c }
    assert_equal 1, results.length
    assert_equal "hello", results.first.content
  end
end
