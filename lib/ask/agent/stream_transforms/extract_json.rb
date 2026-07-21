# frozen_string_literal: true

require "json"

module Ask
  module Agent
    module StreamTransforms
      # Attempts to parse JSON from a streaming LLM text response.
      #
      # When the LLM is instructed to return JSON but structured output
      # (via schema) is not used, the model may emit text that happens
      # to be valid JSON. This transform buffers the text, attempts a
      # JSON parse on each addition, and emits a special chunk with
      # the parsed data when valid JSON is found.
      #
      # This is useful for fallback scenarios where you want structured
      # data without requiring native structured output support from the
      # provider.
      #
      # @example
      #   pipeline.use :extract_json
      #
      #   # The final chunk will have chunk.extracted_json if JSON was parsed.
      class ExtractJson < Base
        def initialize
          @buffer = +""
          @parsed = nil
        end

        def call(chunk, &block)
          if chunk.content.to_s.strip.length > 0
            @buffer << chunk.content

            # Attempt to parse the accumulated buffer as JSON
            begin
              @parsed = JSON.parse(@buffer)
            rescue JSON::ParserError
              # Not valid JSON yet — keep buffering
            end
          end

          # Pass the original chunk through
          yield chunk
        end

        # @return [Hash, nil] the parsed JSON data, if the full response was valid JSON
        def extracted_json
          @parsed
        end

        # @return [Boolean] whether the accumulated response was valid JSON
        def json?
          !@parsed.nil?
        end
      end
    end
  end
end
