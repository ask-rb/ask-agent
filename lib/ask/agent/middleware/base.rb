# frozen_string_literal: true

module Ask
  module Agent
    module Middleware
      # Base class for middleware that wraps LLM provider calls.
      #
      # Subclasses override {#around_request} to inject behavior before, after,
      # or around the provider call. The default implementation yields to the
      # next middleware in the chain (or the actual provider if this is the
      # innermost wrapper).
      #
      # @example A logging middleware
      #   class LogCalls < Base
      #     def around_request(provider, request)
      #       logger.info "LLM call: #{request[:model]}"
      #       start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      #       result = yield
      #       elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      #       logger.info "LLM call finished in #{elapsed.round(3)}s"
      #       result
      #     end
      #   end
      class Base
        # Called before/after each provider.chat(...) call.
        #
        # @param provider [Object] the LLM provider instance
        # @param request [Hash] the request parameters (:messages, :model, :tools, etc.)
        # @yield call the next middleware (or the actual provider)
        # @return [Object] the provider's response
        def around_request(provider, request)
          yield
        end
      end
    end
  end
end
