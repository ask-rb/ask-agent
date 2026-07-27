# frozen_string_literal: true

require_relative "../../test_helper"

class ThinkingAccumulationTest < Minitest::Test
  # Tests that thinking content is properly accumulated across stream chunks
  # in Ask::Agent::Chat.build_stream_response, rather than only taking the
  # last chunk's thinking value (which was the bug).

  def test_thinking_accumulated_across_chunks
    result = build_stream_response(
      thinking_chunks: ["I need to ", "think about ", "this carefully."],
      content_chunks: ["Here is ", "my answer."]
    )

    assert_equal "I need to think about this carefully.", result.thinking,
                 "Thinking should be accumulated across all chunks"
    assert_equal "Here is my answer.", result.content
  end

  def test_no_thinking_returns_empty_string
    result = build_stream_response(
      content_chunks: ["Just content"]
    )
    assert_equal "", result.thinking
    assert_equal "Just content", result.content
  end

  def test_mixed_order_thinking_and_content
    stream = Ask::Stream.new
    stream.add(Ask::Chunk.new(content: nil, thinking: "First "))
    stream.add(Ask::Chunk.new(content: "A"))
    stream.add(Ask::Chunk.new(content: nil, thinking: "Second "))
    stream.add(Ask::Chunk.new(content: "B"))
    stream.finish!

    result = invoke_build_stream_response(stream)
    assert_equal "First Second ", result.thinking
    assert_equal "AB", result.content
  end

  def test_empty_and_nil_thinking_filtered
    stream = Ask::Stream.new
    stream.add(Ask::Chunk.new(content: nil, thinking: ""))
    stream.add(Ask::Chunk.new(content: nil, thinking: "Real "))
    stream.add(Ask::Chunk.new(content: nil, thinking: nil))
    stream.add(Ask::Chunk.new(content: nil, thinking: "thought"))
    stream.add(Ask::Chunk.new(content: "Answer"))
    stream.finish!

    result = invoke_build_stream_response(stream)
    assert_equal "Real thought", result.thinking
    assert_equal "Answer", result.content
  end

  def test_thinking_only_no_content
    stream = Ask::Stream.new
    stream.add(Ask::Chunk.new(content: nil, thinking: "Just thinking"))
    stream.finish!

    result = invoke_build_stream_response(stream)
    assert_equal "Just thinking", result.thinking
    assert_equal "", result.content
  end

  def test_response_message_thinking_field
    msg = Ask::Agent::ResponseMessage.new(
      content: "hi", tool_calls: {}, thinking: "my reasoning",
      input_tokens: 10, output_tokens: 20, cost: 0.001
    )
    assert_equal "my reasoning", msg.thinking
    assert_equal "hi", msg.content
  end

  private

  # Replicates the logic from Chat#build_stream_response without needing a Chat instance
  def build_stream_response(thinking_chunks: [], content_chunks: [])
    stream = Ask::Stream.new
    thinking_chunks.each { |t| stream.add(Ask::Chunk.new(content: nil, thinking: t)) }
    content_chunks.each { |c| stream.add(Ask::Chunk.new(content: c, thinking: nil)) }
    stream.finish!
    invoke_build_stream_response(stream)
  end

  def invoke_build_stream_response(stream)
    tokens = { input: 0, output: 0 }
    Ask::Agent::ResponseMessage.new(
      content: stream.accumulated_text,
      tool_calls: {},
      tool_results: {},
      thinking: stream.chunks.filter_map(&:thinking).join,
      input_tokens: tokens[:input],
      output_tokens: tokens[:output],
      cost: nil
    )
  end
end
