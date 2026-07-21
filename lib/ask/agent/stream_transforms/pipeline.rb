# frozen_string_literal: true

module Ask
  module Agent
    module StreamTransforms
      # A composable chain of {Base} transforms applied to LLM stream chunks.
      #
      # Transforms are applied in order — the first registered transform sees
      # each chunk first. Each transform may yield zero, one, or many chunks
      # downstream.
      #
      # @example
      #   pipeline = Pipeline.new
      #   pipeline.use :thinking_separator
      #   pipeline.use :text_buffer, min_size: 100
      #
      #   wrapped_block = pipeline.wrap { |chunk| handle_chunk(chunk) }
      #   stream.each { |chunk| wrapped_block.call(chunk) }
      #   pipeline.flush { |chunk| handle_chunk(chunk) }
      class Pipeline
        KNOWN_TRANSFORMS = {
          thinking_separator: "Ask::Agent::StreamTransforms::ThinkingSeparator",
          text_buffer: "Ask::Agent::StreamTransforms::TextBuffer",
          extract_json: "Ask::Agent::StreamTransforms::ExtractJson"
        }.freeze

        def initialize
          @transforms = []
        end

        # Register a transform in the chain.
        #
        # @param transform [Symbol, Class] a symbol from KNOWN_TRANSFORMS or a StreamTransforms::Base subclass
        # @param options [Hash] keyword arguments passed to the transform's constructor
        def use(transform, **options)
          klass = resolve(transform)
          @transforms << klass.new(**options)
          self
        end

        # @return [Boolean] whether any transform has been registered
        def configured?
          @transforms.any?
        end

        # Iterate over the configured transform instances.
        def each(&block)
          @transforms.each(&block)
        end

        # Wrap a chunk-processing block with the transform chain.
        #
        # The returned block accepts raw {Ask::Chunk}s, runs them through
        # each transform in sequence, and yields only to the original block
        # for chunks that survive the chain.
        #
        # @yield [Ask::Chunk] transformed chunks
        # @return [Proc] a wrapped block that accepts raw chunks
        def wrap(&block)
          return block unless configured?

          chain = block
          @transforms.reverse_each do |transform|
            current = chain
            chain = ->(chunk) { transform.call(chunk) { |c| current.call(c) } }
          end
          chain
        end

        # Flush any remaining buffered state from all transforms.
        #
        # Call this once when the stream finishes to ensure buffering
        # transforms (e.g. TextBuffer) emit their final content.
        #
        # @yield [Ask::Chunk] final chunks
        def flush(&block)
          @transforms.each do |transform|
            transform.finish { |c| block.call(c) if block }
          end
        end

        private

        def resolve(transform)
          case transform
          when Symbol
            name = KNOWN_TRANSFORMS[transform]
            raise ArgumentError, "Unknown stream transform: #{transform.inspect}" unless name

            name.split("::").reduce(Object) { |mod, k| mod.const_get(k) }
          when Class
            unless transform < Base
              raise ArgumentError, "#{transform} is not a StreamTransforms::Base subclass"
            end

            transform
          else
            raise ArgumentError, "Expected a Symbol or Class, got #{transform.class}"
          end
        end
      end
    end
  end
end
