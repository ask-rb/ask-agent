# frozen_string_literal: true

module Ask
  module Agent
    module Middleware
      # Logs LLM provider calls — request details, duration, token usage, and errors.
      #
      # Uses a configurable logger (defaults to `$stdout` via Ruby's `Logger`).
      # Each call is logged at `INFO` level on success, `WARN` level on failure.
      #
      # @example
      #   pipeline.use :log_calls, logger: Rails.logger
      class LogCalls < Base
        def initialize(logger: nil)
          @logger = logger || default_logger
        end

        def around_request(provider, request)
          model = request[:model]
          tool_count = request[:tools]&.length.to_i
          msg_count = request[:messages]&.length.to_i

          @logger.info("[ask-agent] LLM call starting — model=#{model} tools=#{tool_count} messages=#{msg_count}")

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            result = yield

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

            if result.respond_to?(:accumulated_usage)
              usage = result.accumulated_usage
              tokens = "#{usage[:input_tokens] || '?'}i / #{usage[:output_tokens] || '?'}o"
              @logger.info("[ask-agent] LLM call completed — model=#{model} duration=#{elapsed.round(3)}s tokens=#{tokens}")
            elsif result.respond_to?(:content)
              @logger.info("[ask-agent] LLM call completed — model=#{model} duration=#{elapsed.round(3)}s content_length=#{result.content.to_s.length}")
            else
              @logger.info("[ask-agent] LLM call completed — model=#{model} duration=#{elapsed.round(3)}s")
            end

            result
          rescue StandardError => e
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            @logger.warn("[ask-agent] LLM call failed — model=#{model} duration=#{elapsed.round(3)}s error=#{e.class}(#{e.message})")
            raise
          end
        end

        private

        def default_logger
          require "logger"
          Logger.new($stdout).tap { |l| l.formatter = ->(s, t, _p, msg) { "[#{t.strftime("%H:%M:%S")}] #{msg}\n" } }
        end
      end
    end
  end
end
