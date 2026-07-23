# frozen_string_literal: true

module Ask
  module Agent
    module Middleware
      # Switches to a fallback model+provider when the primary LLM call fails
      # with a transient error (rate limit, server error, service unavailable).
      #
      # Each fallback specifies both a model and a provider slug, so the
      # middleware can switch from e.g. OpenAI to Anthropic transparently.
      # Credentials for each provider are resolved automatically via
      # {Ask::Auth.resolve}.
      #
      # @example Basic usage — fallback to Anthropic when OpenAI is overloaded
      #   pipeline.use :model_fallback, fallbacks: [
      #     { model: "claude-sonnet-4",     provider: :anthropic },
      #     { model: "gemini-2.0-flash",    provider: :google }
      #   ]
      #
      # @example With failure-trigger customization
      #   pipeline.use :model_fallback, fallbacks: [
      #     { model: "claude-sonnet-4", provider: :anthropic, on_error: [Ask::RateLimitError, Ask::ServerError] }
      #   ]
      #
      # @example Using the block form to choose fallbacks dynamically
      #   pipeline.use :model_fallback, fallbacks: ->(error, request) {
      #     if request[:messages].sum { |m| m[:content].to_s.length } > 100_000
      #       [{ model: "claude-sonnet-4", provider: :anthropic }]  # use long-context model
      #     else
      #       [{ model: "gpt-4o-mini", provider: :openai }]          # use cheaper model
      #     end
      #   }
      class ModelFallback < Base
        DEFAULT_ELIGIBLE_ERRORS = [
          Ask::RateLimitError, Ask::ServerError, Ask::ServiceUnavailable
        ].freeze

        def initialize(fallbacks:, eligible_errors: nil)
          @fallbacks = fallbacks.respond_to?(:call) ? fallbacks : Array(fallbacks)
          @eligible_errors = Array(eligible_errors || DEFAULT_ELIGIBLE_ERRORS)
          raise ArgumentError, "At least one fallback is required" if Array(@fallbacks).empty?
        end

        def around_request(provider, request)
          # Try primary provider
          begin
            return yield
          rescue *@eligible_errors => e
            result = try_fallbacks(request, error: e)
            return result if result
            raise
          end
        end

        private

        def try_fallbacks(request, error:)
          fallback_list = resolve_fallback_list(error, request)

          fallback_list.each do |fb|
            begin
              new_provider = build_fallback_provider(fb[:provider])
              request[:model] = fb[:model]
              return invoke_fallback(new_provider, request)
            rescue *@eligible_errors
              next  # Try next fallback
            end
          end

          nil  # All fallbacks exhausted
        end

        def resolve_fallback_list(error, request)
          list = if @fallbacks.respond_to?(:call)
            @fallbacks.call(error, request)
          else
            @fallbacks
          end
          raise "Fallback list must be an array of hashes, got #{list.class}" unless list.is_a?(Array)
          list
        end

        def build_fallback_provider(provider_slug)
          slug = provider_slug.to_s
          klass = Ask::Provider.resolve(slug)
          klass.new(fallback_config(slug))
        end

        def invoke_fallback(provider, request)
          provider.chat(
            request[:messages],
            model: request[:model],
            tools: request[:tools],
            temperature: request[:temperature],
            stream: request[:stream],
            schema: request[:schema],
            **request[:extra_params]
          )
        end

        def fallback_config(slug)
          key = Ask::Auth.resolve(:"#{slug}_api_key") rescue nil
          config = { api_key: key }
          config[:"#{slug}_api_key"] = key
          Ask::LLM::Config.new(config)
        end
      end
    end
  end
end
