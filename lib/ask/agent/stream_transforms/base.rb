# frozen_string_literal: true

module Ask
  module Agent
    module StreamTransforms
      # Base class for stream transforms that process {Ask::Chunk}s.
      #
      # Each transform receives every chunk from the LLM stream and can
      # modify, filter, or buffer it. To emit zero or more transformed chunks,
      # yield to the provided block.
      #
      # @example A simple pass-through transform
      #   class NoOp < Base
      #     def call(chunk, &block)
      #       yield chunk
      #     end
      #   end
      #
      # @example A transform that drops thinking-only chunks
      #   class DropThinking < Base
      #     def call(chunk, &block)
      #       yield chunk unless chunk.thinking? && chunk.content.to_s.empty?
      #     end
      #   end
      class Base
        # Process a single chunk from the LLM stream.
        #
        # @param chunk [Ask::Chunk] the raw chunk from the LLM provider
        # @yield [Ask::Chunk] zero or more transformed chunks
        def call(chunk, &block)
          yield chunk
        end

        # Called once when the stream finishes, giving buffering transforms
        # a chance to flush any remaining state. The default is a no-op.
        #
        # @yield [Ask::Chunk] final chunks to emit
        def finish(&block)
          # no-op
        end
      end
    end
  end
end
