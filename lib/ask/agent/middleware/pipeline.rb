# frozen_string_literal: true

module Ask
  module Agent
    module Middleware
      # A composable chain of middleware that wraps an LLM provider.
      #
      # Middleware are applied in order — the first middleware registered wraps
      # the outermost layer and sees the request first.
      #
      # @example
      #   pipeline = Pipeline.new
      #   pipeline.use :retry_on_failure, max_retries: 5
      #   pipeline.use :log_calls, logger: Rails.logger
      #   pipeline.use :default_settings, temperature: 0.7
      #
      #   result = pipeline.invoke(provider, request) { provider.chat(**request) }
      class Pipeline
        KNOWN_MIDDLEWARES = {
          retry_on_failure: "Ask::Agent::Middleware::RetryOnFailure",
          log_calls: "Ask::Agent::Middleware::LogCalls",
          default_settings: "Ask::Agent::Middleware::DefaultSettings"
        }.freeze

        def initialize
          @entries = []
        end

        # Register a middleware in the chain.
        #
        # @param middleware [Symbol, Class] a symbol from KNOWN_MIDDLEWARES or a Middleware::Base subclass
        # @param options [Hash] keyword arguments passed to the middleware's constructor
        def use(middleware, **options)
          klass = resolve(middleware)
          @entries << { klass: klass, options: options }
          self
        end

        # @return [Boolean] whether any middleware has been registered
        def configured?
          @entries.any?
        end

        # Iterate over the configured middleware entries.
        def each(&block)
          @entries.each(&block)
        end

        # Invoke the middleware chain around a provider call.
        #
        # Builds a chain of lambdas from the innermost (actual provider) outward,
        # then invokes it. Each middleware's {Base#around_request} wraps the next
        # link.
        #
        # @param provider [Object] the LLM provider
        # @param request [Hash] the request parameters
        # @yield the inner block that calls the provider
        # @return [Object] the provider response
        def invoke(provider, request)
          inner = -> { yield }

          chain = inner
          @entries.reverse_each do |entry|
            instance = entry[:klass].new(**entry[:options])
            current = chain
            chain = -> { instance.around_request(provider, request) { current.call } }
          end

          chain.call
        end

        private

        def resolve(middleware)
          case middleware
          when Symbol
            name = KNOWN_MIDDLEWARES[middleware]
            raise ArgumentError, "Unknown middleware: #{middleware.inspect}" unless name

            name.split("::").reduce(Object) { |mod, k| mod.const_get(k) }
          when Class
            unless middleware < Base
              raise ArgumentError, "#{middleware} is not a Middleware::Base subclass"
            end

            middleware
          else
            raise ArgumentError, "Expected a Symbol or Class, got #{middleware.class}"
          end
        end
      end
    end
  end
end
