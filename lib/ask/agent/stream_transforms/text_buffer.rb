# frozen_string_literal: true

module Ask
  module Agent
    module StreamTransforms
      # Buffers rapid text deltas into larger contiguous chunks.
      #
      # LLM streaming often produces many tiny deltas (1–5 characters each),
      # especially over high-latency connections. This transform coalesces
      # them into chunks of at least `min_size` characters, reducing the
      # number of UI updates, log entries, or event emissions.
      #
      # Only text content is buffered. Non-content chunks (tool calls,
      # finish signals, usage data) pass through immediately.
      #
      # @example Buffer until at least 100 characters
      #   pipeline.use :text_buffer, min_size: 100
      class TextBuffer < Base
        def initialize(min_size: 50)
          @min_size = min_size
          @buffer = +""
          @pending_usage = nil
          @pending_finish = nil
        end

        def call(chunk, &block)
          if chunk.content.to_s.strip.length > 0
            @buffer << chunk.content

            if @buffer.length >= @min_size
              emit_buffer(&block)
            end
          else
            # Flush buffer before non-content chunks
            emit_buffer(&block)

            # Track metadata to emit after flush
            if chunk.finish_reason
              @pending_finish = chunk.finish_reason
            end
            if chunk.usage
              @pending_usage = chunk.usage
            end

            # Pass through non-content chunks (tool calls, etc.)
            yield chunk
          end
        end

        def finish(&block)
          emit_buffer(&block) if @buffer.length > 0

          # Emit pending metadata if any
          if @pending_finish || @pending_usage
            yield Ask::Chunk.new(
              content: nil,
              tool_calls: nil,
              finish_reason: @pending_finish,
              usage: @pending_usage,
              raw: nil,
              thinking: nil
            )
            @pending_finish = nil
            @pending_usage = nil
          end
        end

        private

        def emit_buffer(&block)
          return if @buffer.empty?

          yield Ask::Chunk.new(
            content: @buffer.dup,
            tool_calls: nil,
            finish_reason: nil,
            usage: nil,
            raw: nil,
            thinking: nil
          )
          @buffer.clear
        end
      end
    end
  end
end
