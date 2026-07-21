# frozen_string_literal: true

module Ask
  module Agent
    module Middleware
      # Retries LLM provider calls on transient failures.
      #
      # Retries on:
      # - {Ask::RateLimitError} with exponential backoff + jitter
      # - {Ask::ServerError} (5xx) with exponential backoff
      #
      # Does NOT retry on:
      # - {Ask::Unauthorized} — credentials are wrong, retrying won't help
      # - {Ask::InvalidCredential} — same
      # - {Ask::ModelNotFound} — model doesn't exist
      # - {Ask::ConfigurationError} — user config issue
      #
      # @example
      #   pipeline.use :retry_on_failure, max_retries: 5
      class RetryOnFailure < Base
        DEFAULT_MAX_RETRIES = 3

        def initialize(max_retries: DEFAULT_MAX_RETRIES)
          @max_retries = max_retries
        end

        def around_request(provider, request)
          last_error = nil

          @max_retries.times do |attempt|
            begin
              return yield
            rescue Ask::RateLimitError => e
              raise if attempt >= @max_retries - 1

              delay = e.retry_after || compute_backoff(attempt)
              sleep(delay)
              last_error = e
            rescue Ask::ServerError, Ask::ServiceUnavailable => e
              raise if attempt >= @max_retries - 1

              sleep(compute_backoff(attempt))
              last_error = e
            rescue Ask::Unauthorized, Ask::InvalidCredential,
                   Ask::ModelNotFound, Ask::ConfigurationError
              raise
            end
          end

          raise last_error if last_error
        end

        private

        def compute_backoff(attempt)
          (2**attempt) + rand(0.0..1.0)
        end
      end
    end
  end
end
