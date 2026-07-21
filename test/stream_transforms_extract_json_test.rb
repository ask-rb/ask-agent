# frozen_string_literal: true

require_relative "test_helper"

class StreamTransformsExtractJsonTest < Minitest::Test
  def setup
    @transform = Ask::Agent::StreamTransforms::ExtractJson.new
  end

  def test_passthrough_non_json_content
    chunk = Ask::Chunk.new(content: "Hello world")
    results = []
    @transform.call(chunk) { |c| results << c }
    assert_equal 1, results.length
    assert_equal "Hello world", results.first.content
    refute @transform.json?
  end

  def test_accumulates_and_parses_json
    @transform.call(Ask::Chunk.new(content: '{"name"')) { |_c| }
    refute @transform.json?

    @transform.call(Ask::Chunk.new(content: ':"test"}')) { |_c| }
    assert @transform.json?
    assert_equal "test", @transform.extracted_json["name"]
  end

  def test_nested_json
    @transform.call(Ask::Chunk.new(content: '{"user":{"name":"Alice","age":30}}')) { |_c| }
    assert @transform.json?
    assert_equal "Alice", @transform.extracted_json["user"]["name"]
    assert_equal 30, @transform.extracted_json["user"]["age"]
  end

  def test_array_json
    @transform.call(Ask::Chunk.new(content: "[1,2,3]")) { |_c| }
    assert @transform.json?
    assert_equal [1, 2, 3], @transform.extracted_json
  end

  def test_streaming_partial_parse
    chunks = ['{"users":', '[{"id":1,', '"name":"Alice"', '}]}']
    chunks.each { |c| @transform.call(Ask::Chunk.new(content: c)) { |_ch| } }

    assert @transform.json?
    assert_equal 1, @transform.extracted_json["users"].first["id"]
  end

  def test_not_json_for_invalid_input
    @transform.call(Ask::Chunk.new(content: "{broken json")) { |_c| }
    refute @transform.json?
    assert_nil @transform.extracted_json
  end
end
