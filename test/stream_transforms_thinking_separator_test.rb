# frozen_string_literal: true

require_relative "test_helper"

class StreamTransformsThinkingSeparatorTest < Minitest::Test
  def setup
    @transform = Ask::Agent::StreamTransforms::ThinkingSeparator.new
  end

  def test_passthrough_chunk_without_thinking
    chunk = Ask::Chunk.new(content: "Hello")
    results = []
    @transform.call(chunk) { |c| results << c }
    assert_equal 1, results.length
    assert_equal "Hello", results.first.content
    assert_nil results.first.thinking
  end

  def test_passthrough_pure_thinking_chunk
    chunk = Ask::Chunk.new(content: nil, thinking: "I should calculate step by step")
    results = []
    @transform.call(chunk) { |c| results << c }
    assert_equal 1, results.length
    assert_nil results.first.content
    assert_equal "I should calculate step by step", results.first.thinking
  end

  def test_splits_chunk_with_both_thinking_and_content
    chunk = Ask::Chunk.new(content: "The answer is 42", thinking: "Let me think about this")
    results = []
    @transform.call(chunk) { |c| results << c }
    assert_equal 2, results.length, "Should emit thinking and content separately"
    assert_nil results[0].content
    assert_equal "Let me think about this", results[0].thinking
    assert_equal "The answer is 42", results[1].content
    assert_nil results[1].thinking
  end

  def test_preserves_tool_calls_on_content_chunk
    chunk = Ask::Chunk.new(
      content: "Using tool",
      thinking: "I need to call a tool",
      tool_calls: [{ id: "call_1", name: "search", arguments: "{}" }]
    )
    results = []
    @transform.call(chunk) { |c| results << c }

    content_chunk = results.last
    assert_equal "Using tool", content_chunk.content
  end

  def test_pipeline_integration
    pipeline = Ask::Agent::StreamTransforms::Pipeline.new
    pipeline.use :thinking_separator

    received = []
    wrapped = pipeline.wrap { |c| received << c }

    wrapped.call(Ask::Chunk.new(content: "Visible", thinking: "Hidden"))
    wrapped.call(Ask::Chunk.new(content: "More visible"))

    assert_equal 3, received.length
    assert_nil received[0].content
    assert_equal "Hidden", received[0].thinking
    assert_equal "Visible", received[1].content
    assert_equal "More visible", received[2].content
  end
end
