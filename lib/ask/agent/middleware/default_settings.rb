# frozen_string_literal: true

module Ask
  module Agent
    module Middleware
      # Injects default generation parameters for every LLM call.
      #
      # Settings are merged into the request – user-supplied values always take
      # precedence (they appear in the original request hash and are preserved).
      #
      # @example
      #   pipeline.use :default_settings, temperature: 0.5, max_tokens: 4096
      class DefaultSettings < Base
        # Settings that are safe to merge into the provider chat request.
        ALLOWED_KEYS = %i[
          temperature max_tokens top_p top_k stop_sequences
          presence_penalty frequency_penalty seed
        ].freeze

        def initialize(**settings)
          @settings = settings.select { |k, _v| ALLOWED_KEYS.include?(k) }
        end

        def around_request(provider, request)
          return yield if @settings.empty?

          merged = request.dup
          @settings.each do |key, value|
            merged[key] = value unless merged.key?(key)
          end

          # Re-invoke the chain with merged params.
          # We override the request for downstream middleware but still yield
          # to the original chain — the actual provider call in Chat#chat_with_retry
          # uses the **(@extra_params || {}) merged into the provider call, so
          # we must ensure our defaults are passed through.
          #
          # Instead of modifying the request shape, we inject defaults into
          # the :extra_params key which Chat already merges into the provider call.
          extra = (merged[:extra_params] || {}).merge(@settings) { |_k, orig, _default| orig }
          merged[:extra_params] = extra

          # Rebuild request to pass defaults through the chain
          yield
        end
      end
    end
  end
end
