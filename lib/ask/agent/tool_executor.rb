# frozen_string_literal: true

module Ask
  module Agent
    class ToolExecutor
      CRITICAL_ERROR_CLASSES = %w[
        Ask::Unauthorized
        Ask::Forbidden
        Ask::PaymentRequired
      ].freeze

      attr_reader :total_executions

      def initialize(max_retries: 3, parallel: true)
        @max_retries = max_retries
        @parallel = parallel
        @total_executions = 0
      end

      attr_writer :telemetry

      def execute(tool_calls, tools, hooks:, event_emitter:, session_id: nil)
        return [] if tool_calls.empty?

        @total_executions = 0
        @session_id = session_id
        sibling_abort = ToolAbortController.new

        if @parallel
          execute_parallel(tool_calls, tools, hooks, event_emitter, sibling_abort)
        else
          execute_sequential(tool_calls, tools, hooks, event_emitter, sibling_abort)
        end
      end

      def execute_parallel(tool_calls, tools, hooks, event_emitter, sibling_abort, &result_callback)
        threads = []
        mutex = Mutex.new
        results = {}

        tool_calls.each do |id, tool_call|
          threads << Thread.new do
            begin
              if sibling_abort.aborted?
                mutex.synchronize { results[id] = aborted_result(tool_call) }
                next
              end

              result = execute_single_tool(tool_call, tools, hooks, event_emitter, sibling_abort)
              mutex.synchronize { results[id] = result }

              # Stream result back as it completes
              result_callback&.call(tool_call.id, result)

              if result[:critical_failure]
                sibling_abort.abort!
              end

              if result[:halted]
                sibling_abort.abort!
              end
            rescue => e
              mutex.synchronize do
                results[id] = {
                  tool_name: tool_call.name, message: e.message,
                  status: "error", is_error: true, critical_failure: false
                }
              end
              result_callback&.call(tool_call.id, results[id])
            end
          end
        end

        threads.each(&:join)
        tool_calls.keys.map { |id| results[id] }.compact
      end

      def execute_sequential(tool_calls, tools, hooks, event_emitter, sibling_abort)
        results = []
        tool_calls.each do |id, tool_call|
          break if sibling_abort.aborted?

          result = execute_single_tool(tool_call, tools, hooks, event_emitter, sibling_abort)
          results << result
          break if result[:critical_failure]
          break if result[:halted]
        end
        results
      end

      private

      def execute_single_tool(tool_call, tools, hooks, event_emitter, abort_controller = nil)
        return aborted_result(tool_call) if abort_controller&.aborted?

        tool = tools.find { |t| t.name == tool_call.name }

        unless tool
          return { tool_name: tool_call.name, message: "Tool not found", status: "error", is_error: true }
        end

        hook_result = hooks.run_before_tool(tool_call, {})
        case hook_result&.dig(:action)
        when :block
          return { tool_name: tool_call.name, message: hook_result[:reason], status: "blocked", is_error: true }
        when :short_circuit
          return { tool_name: tool_call.name, **hook_result[:result], status: "short_circuited" }
        end

        return aborted_result(tool_call) if abort_controller&.aborted?

        args = hook_result&.dig(:arguments) || tool_call.arguments

        event_emitter.emit(Events::ToolExecutionStart.new(
          name: tool_call.name, arguments: args, id: tool_call.id
        ))

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = begin
          execute_with_retry(tool, tool_call.id, args, abort_controller)
        rescue Exception => e
          { result: e.message, is_error: true, error: e.class.name }
        end
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).to_i
        @total_executions += 1

        return aborted_result(tool_call) if abort_controller&.aborted?

        hook_result = hooks.run_after_tool(tool_call, result, {})
        if hook_result&.dig(:action) == :transform
          result = hook_result[:result]
        end

        is_error = result[:is_error] == true
        critical = is_error && critical_error?(result[:error])
        halted = result[:halted] == true

        if halted
          abort_controller&.abort!
        end

        if is_error && @telemetry
          @telemetry.log(:tool_error, session_id: @session_id, tool_name: tool_call.name, error_class: result[:error] || "RuntimeError", error_message: result[:result].to_s)
        end

        event_emitter.emit(Events::ToolExecutionEnd.new(
          name: tool_call.name, id: tool_call.id, result: result, is_error: is_error, duration_ms: duration
        ))

        message = if is_error
          tool_result = result[:result]
          error_msg = if tool_result.is_a?(Hash) && tool_result[:error]
            tool_result[:error].to_s
          elsif tool_result.is_a?(String)
            tool_result
          else
            result.to_s
          end
          "Tool #{tool_call.name} error: #{error_msg}"
        else
          result[:result].to_s
        end

        {
          tool_name: tool_call.name,
          message: message,
          status: is_error ? "error" : "success",
          result: result,
          critical_failure: critical,
          halted: halted
        }
      end

      def execute_with_retry(tool, tool_call_id, args, abort_controller = nil)
        @max_retries.times do |attempt|
          return { result: nil, is_error: true, error: "Aborted" } if abort_controller&.aborted?

          result = try_call(tool, args, abort_controller)
          return result unless result[:is_error] && retryable_error_name?(result[:error])

          sleep((2 ** attempt) * 0.5 + rand(0.0..0.5))
        end

        return { result: nil, is_error: true, error: "Aborted" } if abort_controller&.aborted?
        try_call(tool, args)
      end

      def try_call(tool, args, abort_controller = nil)
        result = tool.call(args, abort_controller: abort_controller)
        is_error = result.respond_to?(:ok?) ? !result.ok? : false
        hash = { result: result, is_error: is_error }
        if result.respond_to?(:metadata) && result.metadata&.dig(:halted)
          hash[:halted] = true
        end
        hash
      rescue => e
        { result: e.message, is_error: true, error: e.class.name }
      end

      def retryable_error_name?(error_name)
        return false unless error_name

        klass = Object.const_get(error_name) rescue nil
        return false unless klass

        klass <= Ask::RateLimitError ||
        klass <= Ask::ServerError ||
        klass <= Ask::ServiceUnavailable ||
        %w[Timeout::Error Errno::ETIMEDOUT].include?(error_name)
      end

      def critical_error?(error_class_name)
        return false unless error_class_name
        CRITICAL_ERROR_CLASSES.any? { |klass| error_class_name == klass }
      end

      def aborted_result(tool_call)
        {
          tool_name: tool_call.name,
          message: "Aborted by sibling failure",
          status: "aborted",
          is_error: true,
          aborted: true
        }
      end
    end
  end
end
