# frozen_string_literal: true

module Ask
  module Agent
    module StreamTransforms
      # Separates thinking/reasoning content from visible text content in the
      # stream. Useful when you want to handle thinking tokens separately
      # (e.g., display them in a collapsible UI section or log them for
      # debugging).
      #
      # Some LLM providers (notably Anthropic) send thinking content as
      # separate chunks with both `content` and `thinking` fields populated.
      # This transform splits those into two chunks: a thinking-only chunk
      # (with the thinking content) and a text-only chunk (with the visible
      # content), so downstream code can handle each independently.
      #
      # @example
      #   pipeline.use :thinking_separator
      #
      #   # Now chunks arrive as:
      #   #   chunk.content? && !chunk.thinking?  → visible text
      #   #   chunk.thinking? && !chunk.content?  → thinking text
      class ThinkingSeparator < Base
        def call(chunk, &block)
          if chunk.thinking? && chunk.content.to_s.strip.length > 0
            # Split: emit thinking first, then content
            yield Ask::Chunk.new(
              content: nil,
              tool_calls: nil,
              finish_reason: nil,
              usage: nil,
              raw: nil,
              thinking: chunk.thinking
            )

            yield Ask::Chunk.new(
              content: chunk.content,
              tool_calls: chunk.tool_calls,
              finish_reason: chunk.finish_reason,
              usage: chunk.usage,
              raw: chunk.raw,
              thinking: nil
            )
          elsif chunk.thinking? && chunk.content.to_s.strip.empty?
            # Pure thinking chunk — pass through as-is
            yield chunk
          else
            # No thinking — pass through
            yield chunk
          end
        end
      end
    end
  end
end
