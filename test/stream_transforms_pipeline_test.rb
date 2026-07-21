# frozen_string_literal: true

require_relative "test_helper"

class StreamTransformsPipelineTest < Minitest::Test
  def setup
    @pipeline = Ask::Agent::StreamTransforms::Pipeline.new
  end

  def test_empty_pipeline_not_configured
    refute @pipeline.configured?
  end

  def test_pipeline_with_transform_is_configured
    @pipeline.use :thinking_separator
    assert @pipeline.configured?
  end

  def test_use_with_symbol_resolves_builtin
    @pipeline.use :text_buffer, min_size: 100
    assert @pipeline.configured?
  end

  def test_use_with_class
    @pipeline.use Ask::Agent::StreamTransforms::ThinkingSeparator
    assert @pipeline.configured?
  end

  def test_use_with_invalid_symbol_raises
    assert_raises(ArgumentError) { @pipeline.use :nonexistent }
  end

  def test_use_with_non_transform_class_raises
    assert_raises(ArgumentError) { @pipeline.use String }
  end

  def test_wrap_passthrough_with_no_transforms
    block = @pipeline.wrap { |c| "handled-#{c.content}" }
    result = block.call(Ask::Chunk.new(content: "hello"))
    assert_equal "handled-hello", result
  end

  def test_wrap_chains_transforms
    log = []
    @pipeline.use Class.new(Ask::Agent::StreamTransforms::Base) {
      define_method(:call) { |c, &b| log << :first; b.call(c) }
    }
    @pipeline.use Class.new(Ask::Agent::StreamTransforms::Base) {
      define_method(:call) { |c, &b| log << :second; b.call(c) }
    }

    wrapped = @pipeline.wrap { |c| log << :inner; c.content }
    wrapped.call(Ask::Chunk.new(content: "x"))
    assert_equal [:first, :second, :inner], log
  end

  def test_transform_can_drop_chunks
    @pipeline.use Class.new(Ask::Agent::StreamTransforms::Base) {
      define_method(:call) { |c, &b| b.call(c) if c.content != "drop" }
    }

    received = []
    wrapped = @pipeline.wrap { |c| received << c.content }
    wrapped.call(Ask::Chunk.new(content: "keep"))
    wrapped.call(Ask::Chunk.new(content: "drop"))
    wrapped.call(Ask::Chunk.new(content: "keep2"))
    assert_equal %w[keep keep2], received
  end

  def test_flush_called_on_all_transforms
    flushed = []
    @pipeline.use Class.new(Ask::Agent::StreamTransforms::Base) {
      define_method(:finish) { |&b| flushed << :a }
    }
    @pipeline.use Class.new(Ask::Agent::StreamTransforms::Base) {
      define_method(:finish) { |&b| flushed << :b }
    }

    @pipeline.flush { }
    assert_equal [:a, :b], flushed
  end

  def test_wrap_returns_block_without_transforms
    assert_equal 0, @pipeline.instance_variable_get(:@transforms).length
    # Without transforms, wrap returns the original block
    original = ->(c) { c.content }
    result = @pipeline.wrap(&original)
    assert_same original, result
  end
end
