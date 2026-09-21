# frozen_string_literal: true

module Ask
  module Agent
    class ToolExecutor
      include Ask::Runtime::ToolExecutor

      CRITICAL_ERROR_CLASSES = %w[
        Ask::Unauthorized
        Ask::Forbidden
        Ask::PaymentRequired
      ].freeze

      attr_reader :total_executions

      def initialize(max_retries: 3, parallel: true, output_offload_threshold: nil, output_store: nil, artifact_store: nil)
        @max_retries = max_retries
        @parallel = parallel
        @total_executions = 0
        @output_offload_threshold = output_offload_threshold
        @output_store = output_store
        @artifact_store = artifact_store
      end

      attr_writer :telemetry

      # Public entry point — dispatches between two contracts:
      #
      #   Batch API:    execute(tool_calls, tools, hooks:, event_emitter:, ...)
      #   Runtime API:  execute(tool_call, context:)
      #
      # The discriminator is the first argument: a Hash triggers the batch path,
      # anything else (typically an Ask::Runtime::ToolCall) triggers the runtime path.
      def execute(tool_calls_or_call, tools_or_context = nil, **rest)
        if tool_calls_or_call.is_a?(Hash)
          execute_batch(tool_calls_or_call, tools_or_context, **rest)
        else
          ctx = rest.key?(:context) ? rest[:context] : tools_or_context
          _runtime_execute(tool_calls_or_call, context: ctx)
        end
      end

      def execute_batch(tool_calls, tools, hooks:, event_emitter:, session_id: nil, turn: nil, result_callback: nil, runtime_event_sink: nil)
        return [] if tool_calls.empty?

        @total_executions = 0
        @session_id = session_id
        @turn = turn
        @last_tools = tools
        sibling_abort = CallbackAbortController.new

        if @parallel
          execute_parallel(tool_calls, tools, hooks, event_emitter, sibling_abort, runtime_event_sink, &result_callback)
        else
          execute_sequential(tool_calls, tools, hooks, event_emitter, sibling_abort, runtime_event_sink) do |id, result|
            result_callback&.call(id, result)
          end
        end
      end

      def execute_parallel(tool_calls, tools, hooks, event_emitter, sibling_abort, runtime_event_sink, &result_callback)
        threads = []
        mutex = Mutex.new
        results = {}

        # Inherit the caller's thread-local state (Rails CurrentAttributes
        # and similar frameworks store per-request context in Thread.current)
        # so tools see the same context they would in a sequential run.
        inherited_locals = {}
        Thread.current.keys.each { |key| inherited_locals[key] = Thread.current[key] }

        tool_calls.each do |id, tool_call|
          threads << Thread.new do
            inherited_locals.each { |key, value| Thread.current[key] = value }
            begin
              if sibling_abort.aborted?
                mutex.synchronize { results[id] = aborted_result(tool_call) }
                next
              end

              result = execute_single_tool(tool_call, tools, hooks, event_emitter, sibling_abort, runtime_event_sink)
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
        tool_calls.keys.filter_map { |id| results[id]&.merge(tool_call_id: id) }
      end

      def execute_sequential(tool_calls, tools, hooks, event_emitter, sibling_abort, runtime_event_sink, &result_callback)
        results = []
        tool_calls.each do |id, tool_call|
          break if sibling_abort.aborted?

          result = execute_single_tool(tool_call, tools, hooks, event_emitter, sibling_abort, runtime_event_sink)
          results << result.merge(tool_call_id: id)
          result_callback&.call(id, result)
          break if result[:critical_failure]
          break if result[:halted]
        end
        results
      end

      private

      class CallbackAbortController < ToolAbortController
        def initialize
          super
          @abort_callbacks = []
        end

        def abort!
          callbacks_to_run = @mutex.synchronize do
            was_aborted = @aborted
            @aborted = true
            was_aborted ? [] : @abort_callbacks.dup
          end
          callbacks_to_run.each(&:call)
          self
        end

        def on_abort(&block)
          raise ArgumentError, "block required" unless block

          already = @mutex.synchronize do
            if @aborted
              true
            else
              @abort_callbacks << block
              false
            end
          end
          block.call if already
          self
        end
      end

      def build_runtime_tool_call(tool_call, effective_args: nil)
        input = begin
          raw = effective_args || tool_call.arguments
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end

        Ask::Runtime::ToolCall.new(
          id: tool_call.id,
          tool_name: tool_call.name,
          input: input,
          session_id: @session_id,
          turn: @turn
        )
      end

      def build_runtime_context(abort_controller)
        canceller = AbortControllerCancellerAdapter.new(abort_controller) if abort_controller

        Ask::Runtime::ExecutionContext.new(
          session_id: @session_id,
          turn: @turn,
          canceller: canceller
        )
      end

      class AbortControllerCancellerAdapter
        def initialize(abort_controller)
          @abort_controller = abort_controller
          @callbacks = []
          @mutex = Mutex.new

          if abort_controller.respond_to?(:on_abort)
            abort_controller.on_abort { fire_callbacks }
          end
        end

        def cancelled?
          @abort_controller.aborted?
        end

        def cancel
          @abort_controller.abort!
          fire_callbacks
          self
        end

        def on_cancel(&block)
          raise ArgumentError, "block required" unless block

          already = @mutex.synchronize do
            if @abort_controller.aborted?
              true
            else
              @callbacks << block
              false
            end
          end
          block.call if already
          self
        end

        def inspect
          "#<Ask::Agent::ToolExecutor::AbortControllerCancellerAdapter cancelled=#{cancelled?}>"
        end

        private

        def fire_callbacks
          callbacks_to_run = @mutex.synchronize do
            snapshot = @callbacks.dup
            @callbacks.clear
            snapshot
          end
          callbacks_to_run.each(&:call)
        end
      end

      # ----------------------------------------------------------------
      # Runtime contract: execute a single tool call and return ToolResult
      # ----------------------------------------------------------------

      # Implements Ask::Runtime::ToolExecutor#execute.
      #
      # This is the single-call entry point for the runtime contract.
      # It does NOT run hooks, emit agent events, or manage batches — it is
      # the pure runtime execution path that the batch API delegates to
      # internally (via execute_single_tool).
      #
      # @param tool_call [Ask::Runtime::ToolCall] the tool-call request
      # @param context [Ask::Runtime::ExecutionContext, nil] execution context
      # @return [Ask::Runtime::ToolResult] the normalized result
      def _runtime_execute(tool_call, context: nil)
        context ||= Ask::Runtime::ExecutionContext.new
        started_at = Time.now
        started_call = tool_call.with(state: :running, started_at: started_at)
        emit_runtime_event(context.event_sink, :tool_started,
          Ask::Runtime::Events::ToolStarted.new(
            tool_call: started_call, execution_context: context, timestamp: started_at
          ))

        return runtime_cancel(started_call, context, started_at, "Cancelled before execution") if context.cancelled?

        tool = find_tool_for_runtime(tool_call.tool_name)

        result = if tool
          invoke_tool_with_retry(tool, tool_call.id, tool_call.input, context.canceller)
        else
          Ask::Runtime::ToolResult.failure("Tool not found: #{tool_call.tool_name}")
        end

        return runtime_cancel(started_call, context, started_at, "Cancelled during execution") if context.cancelled?

        runtime_finish(started_call, context, result, started_at)
      end

      def runtime_finish(started_call, context, result, started_at)
        finished_at = Time.now
        duration = finished_at - started_at
        result = Ask::Runtime::ToolResult.new(
          result: result.result, outcome: result.outcome, duration: duration
        )
        state = if result.timeout?
          :timed_out
        elsif result.failure?
          :failed
        else
          :completed
        end
        finished_call = started_call.with(
          state: state,
          tool_result: result,
          error: result.error_message,
          finished_at: finished_at
        )
        emit_runtime_terminal_event(
          context.event_sink, state,
          tool_call: finished_call, tool_result: result,
          execution_context: context, timestamp: finished_at, duration: duration
        )
        result
      end

      def runtime_cancel(started_call, context, started_at, reason)
        finished_at = Time.now
        duration = finished_at - started_at
        result = Ask::Runtime::ToolResult.new(
          result: Ask::Result.failure(reason), outcome: :cancelled, duration: duration
        )
        finished_call = started_call.with(
          state: :cancelled,
          tool_result: result,
          error: result.error_message,
          finished_at: finished_at
        )
        emit_runtime_terminal_event(
          context.event_sink, :cancelled,
          tool_call: finished_call, tool_result: result,
          execution_context: context, timestamp: finished_at, duration: duration
        )
        result
      end

      # Find a tool by name for the runtime contract path.
      # Uses the last-known tools list from execute_batch, or nil.
      def find_tool_for_runtime(tool_name)
        @last_tools&.find { |t| t.name == tool_name }
      end

      # ----------------------------------------------------------------
      # Shared execution core — used by both batch and runtime paths
      # ----------------------------------------------------------------

      # Invoke a tool with retry logic, returning an Ask::Runtime::ToolResult.
      #
      # This is the single source of truth for tool invocation. It wraps
      # try_call and handles retryable errors, producing a normalized
      # ToolResult that both the batch and runtime paths consume.
      def invoke_tool_with_retry(tool, tool_call_id, args, abort_controller = nil)
        @max_retries.times do |attempt|
          if abort_cancelled?(abort_controller)
            return Ask::Runtime::ToolResult.cancelled("Aborted")
          end

          result = try_call(tool, args, abort_controller)
          return result unless result.failure? && retryable_error?(result)

          sleep((2 ** attempt) * 0.5 + rand(0.0..0.5))
        end

        if abort_cancelled?(abort_controller)
          return Ask::Runtime::ToolResult.cancelled("Aborted")
        end
        try_call(tool, args)
      end

      # Check if the abort controller signals cancellation.
      # Handles both ToolAbortController (aborted?) and Canceller (cancelled?).
      def abort_cancelled?(controller)
        return false unless controller
        return true if controller.respond_to?(:aborted?) && controller.aborted?
        return true if controller.respond_to?(:cancelled?) && controller.cancelled?
        false
      end

      # Invoke a tool once, returning an Ask::Runtime::ToolResult.
      #
      # Normalizes all tool return types (Ask::Result, Hash, String, pending)
      # into the canonical ToolResult shape.  Preserves halted metadata for
      # the batch path to consume.
      def try_call(tool, args, abort_controller = nil)
        raw = tool.call(args, abort_controller: abort_controller)

        if raw.respond_to?(:pending?) && raw.pending?
          return Ask::Runtime::ToolResult.success(data: raw)
        end

        if raw.respond_to?(:ok?)
          if raw.ok?
            # Preserve the Ask::Result as the ToolResult's result object
            # so downstream code can access metadata (e.g. halted flag).
            Ask::Runtime::ToolResult.new(result: raw, outcome: :success)
          else
            Ask::Runtime::ToolResult.failure(extract_error_message(raw))
          end
        else
          Ask::Runtime::ToolResult.success(data: raw)
        end
      rescue => e
        Ask::Runtime::ToolResult.failure("#{e.class}: #{e.message}")
      end

      # Extract the output payload from an Ask::Result, unwrapping the wrapper
      # so ToolResult.output carries the actual data.
      def unwrap_output(result)
        result.respond_to?(:output) ? result.output : result
      end

      # Extract a string error message from a failed Ask::Result.
      def extract_error_message(result)
        msg = result.respond_to?(:error_message) ? result.error_message : nil
        msg || result.to_s
      end

      # Check if a ToolResult represents a retryable error.
      def retryable_error?(tool_result)
        return false unless tool_result.failure?

        error_msg = tool_result.error_message.to_s
        # Extract the class name from "ClassName: message" format.
        # Split on ": " (colon-space) to avoid breaking on :: namespaces.
        error_class_name = error_msg.split(": ").first
        retryable_error_name?(error_class_name)
      end

      # ----------------------------------------------------------------
      # Batch path: execute_single_tool (unchanged public behavior)
      # ----------------------------------------------------------------

      def execute_single_tool(tool_call, tools, hooks, event_emitter, abort_controller = nil, runtime_event_sink = nil)
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
        when :pending
          # Queued for human approval — the loop hands the turn back with an
          # interim reply; the action runs later via ApprovalQueue#approve.
          return {
            tool_name: tool_call.name,
            message: hook_result[:reason] || "Pending approval",
            status: "pending",
            is_error: false,
            tool_call_id: tool_call.id,
            action_id: hook_result[:action_id]
          }
        end

        return aborted_result(tool_call) if abort_controller&.aborted?

        args = hook_result&.dig(:arguments) || tool_call.arguments

        event_emitter.emit(Events::ToolExecutionStart.new(
          name: tool_call.name, arguments: args, id: tool_call.id
        ))

        runtime_call = build_runtime_tool_call(tool_call, effective_args: args)
        # Expose the pending runtime call before execution starts so tools
        # can observe the full pending → running → terminal lifecycle.
        Thread.current[:ask_agent_runtime_call] = runtime_call
        runtime_context = build_runtime_context(abort_controller)

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        start_timestamp = Time.now
        Thread.current[:ask_agent_tool_call_id] = tool_call.id
        Thread.current[:ask_agent_runtime_context] = runtime_context

        # Transition to :running once execution is active and observable by tools.
        running_call = runtime_call.with(state: :running, started_at: start_timestamp)
        Thread.current[:ask_agent_runtime_call] = running_call

        # Emit runtime ToolStarted event (one per tool call).
        emit_runtime_event(runtime_event_sink, :tool_started,
          Ask::Runtime::Events::ToolStarted.new(
            tool_call: running_call, execution_context: runtime_context, timestamp: start_timestamp
          ))

        # Shared execution core — invoke tool with retry, get ToolResult.
        tool_result = begin
          invoke_tool_with_retry(tool, tool_call.id, args, abort_controller)
        rescue Exception => e
          Ask::Runtime::ToolResult.failure("#{e.class}: #{e.message}")
        end

        # Classify into terminal state + legacy agent result hash.
        terminal_state, legacy_result = classify_tool_result(tool_result, abort_controller)

        # Transition runtime call to terminal state and attach ToolResult
        # BEFORE clearing thread locals so tools can observe the full lifecycle
        # including the unwrapped ToolResult.output.
        finished_call = running_call.with(
          state: terminal_state,
          tool_result: tool_result,
          error: tool_result.error_message,
          finished_at: Time.now
        )
        Thread.current[:ask_agent_runtime_call] = finished_call

        # Clear all thread locals — even on errors — so no stale or
        # terminal runtime objects remain in Thread.current after cleanup.
        Thread.current[:ask_agent_tool_call_id] = nil
        Thread.current[:ask_agent_runtime_call] = nil
        Thread.current[:ask_agent_runtime_context] = nil

        duration_secs = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        duration_ms = (duration_secs * 1000).to_i
        @total_executions += 1

        # Emit runtime terminal event (exactly one per tool call).
        emit_runtime_terminal_event(
          runtime_event_sink, terminal_state,
          tool_call: finished_call, tool_result: tool_result,
          execution_context: runtime_context, timestamp: Time.now,
          duration: duration_secs
        )

        return aborted_result(tool_call) if abort_controller&.aborted?

        hook_result = hooks.run_after_tool(tool_call, legacy_result, {})
        if hook_result&.dig(:action) == :transform
          legacy_result = hook_result[:result]
        end

        is_error = legacy_result[:is_error] == true
        critical = is_error && critical_error?(legacy_result[:error])
        halted = legacy_result[:halted] == true

        if halted
          abort_controller&.abort!
        end

        if is_error && @telemetry
          @telemetry.log(:tool_error, session_id: @session_id, tool_name: tool_call.name, error_class: legacy_result[:error] || "RuntimeError", error_message: legacy_result[:result].to_s)
        end

        event_emitter.emit(Events::ToolExecutionEnd.new(
          name: tool_call.name, id: tool_call.id, result: legacy_result, is_error: is_error, duration_ms: duration_ms
        ))

        message = if is_error
          inner = legacy_result[:result]
          error_msg = if inner.is_a?(Hash) && inner[:error]
            inner[:error].to_s
          elsif inner.is_a?(String)
            inner
          else
            legacy_result.to_s
          end
          "Tool #{tool_call.name} error: #{error_msg}"
        else
          legacy_result[:result].to_s
        end

        # Large outputs never enter the transcript: store the full message
        # and keep a short preview plus a reference the model can retrieve
        # with the output_read tool. output_read's own result is exempt —
        # its contract is to bring the full output into context on demand.
        if @output_offload_threshold && message.length > @output_offload_threshold &&
           tool_call.name != "output_read"
          message = offload_message(message, tool_call.id)
        end

        # Collect tool-produced deliverables (metadata[:artifact]) into the
        # session's artifact store. Best-effort: a malformed artifact is
        # noted in the message, never a tool failure.
        if @artifact_store && legacy_result[:result].respond_to?(:metadata) &&
           (artifact = legacy_result[:result].metadata[:artifact])
          begin
            attrs = symbolize_artifact(artifact)
            @artifact_store.store(@session_id, **attrs)
          rescue ArgumentError => e
            message += "\n[artifact not stored: #{e.message}]"
          end
        end

        inner = legacy_result[:result]
        status = if legacy_result[:is_error] == true
          "error"
        elsif inner.respond_to?(:pending?) && inner.pending?
          "pending"
        else
          "success"
        end

        {
          tool_name: tool_call.name,
          message: message,
          status: status,
          result: legacy_result,
          critical_failure: critical,
          halted: halted
        }
      end

      def emit_runtime_event(sink, event_type, event)
        return unless sink

        sink.emit(event_type, event: event)
      end

      def emit_runtime_terminal_event(sink, terminal_state, **attrs)
        return unless sink

        event_class = case terminal_state
                      when :completed then Ask::Runtime::Events::ToolCompleted
                      when :failed then Ask::Runtime::Events::ToolFailed
                      when :cancelled then Ask::Runtime::Events::ToolCancelled
                      when :timed_out then Ask::Runtime::Events::ToolTimedOut
                      else return
                      end
        sink.emit(terminal_event_type(terminal_state), event: event_class.new(**attrs))
      end

      def terminal_event_type(state)
        "tool_#{state}".to_sym
      end

      # Store a large tool message in the output store and return a short
      # preview that references it, so the transcript never carries the full
      # output.
      def offload_message(message, tool_call_id)
        @output_store.store(@session_id, tool_call_id, message)
        preview = message[0, 300]
        "#{preview}\n...(output truncated: #{message.length} chars — full output via output_read id: \"#{tool_call_id}\")"
      end

      # Normalize an artifact hash from tool metadata (accepts string keys)
      # to the store's keyword contract.
      def symbolize_artifact(artifact)
        {
          filename: artifact[:filename] || artifact["filename"],
          mime_type: artifact[:mime_type] || artifact["mime_type"],
          content: artifact[:content] || artifact["content"],
          uri: artifact[:uri] || artifact["uri"]
        }
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

      # Map a ToolResult to a runtime terminal state and a legacy agent
      # result hash.  Returns [terminal_state_symbol, legacy_hash].
      #
      # This is the shared classification logic: the runtime path uses the
      # ToolResult directly; the batch path wraps it in the agent's hash
      # format for backward compatibility.
      def classify_tool_result(tool_result, abort_controller)
        if abort_controller&.aborted?
          return [:cancelled, { result: "Aborted by sibling failure", is_error: true, error: "Aborted" }]
        end

        halted = tool_halted?(tool_result)

        case tool_result.outcome
        when :cancelled
          [:cancelled, { result: tool_result.error_message, is_error: true, error: "Aborted" }]
        when :failure
          error_class = extract_error_class(tool_result.error_message)
          [:failed, { result: tool_result.error_message, is_error: true, error: error_class }]
        when :timeout
          [:timed_out, { result: tool_result.error_message, is_error: true, error: "Timeout" }]
        when :success
          if tool_result.output.respond_to?(:pending?) && tool_result.output.pending?
            [:completed, { result: tool_result.output, is_error: false, halted: halted }]
          else
            # Preserve the original Ask::Result in the legacy hash for
            # backward compatibility — tools that return Ask::Result get
            # their result object in [:result][:result].
            legacy_inner = if tool_result.result.is_a?(Ask::Result)
              tool_result.result
            else
              tool_result.output
            end
            [:completed, { result: legacy_inner, is_error: false, halted: halted }]
          end
        else
          [:completed, { result: tool_result.output, is_error: false, halted: halted }]
        end
      end

      # Detect if a tool result carries halted metadata.
      # Checks the underlying Ask::Result (ToolResult.result) for halted
      # metadata, since that's where tools set it via Ask::Result.ok(..., metadata: { halted: true }).
      def tool_halted?(tool_result)
        return false unless tool_result.success?

        inner = tool_result.result
        inner.respond_to?(:metadata) && inner.metadata&.dig(:halted) == true
      end

      # Extract the error class name from a tool failure message.
      # Messages from try_call are formatted as "ClassName: message".
      # Split on ": " (colon-space) to avoid breaking on :: namespaces.
      def extract_error_class(error_message)
        return "Error" unless error_message
        error_message.split(": ").first || "Error"
      end

      # Legacy classify_result for backward compatibility with code that
      # passes raw agent result hashes.  Delegates to the shared
      # classify_tool_result after wrapping the hash in a ToolResult.
      def classify_result(result, abort_controller)
        tool_result = if abort_controller&.aborted?
          Ask::Runtime::ToolResult.cancelled("Aborted by sibling failure")
        elsif result[:is_error] == true
          error_msg = extract_error_from_hash(result)
          Ask::Runtime::ToolResult.failure(error_msg)
        else
          inner = result[:result]
          if inner.respond_to?(:pending?) && inner.pending?
            Ask::Runtime::ToolResult.success(data: inner)
          else
            data = if inner.is_a?(Ask::Result)
              inner.output
            elsif inner.is_a?(Hash) && inner.key?(:result)
              inner[:result]
            else
              inner
            end
            Ask::Runtime::ToolResult.success(data: data)
          end
        end

        classify_tool_result(tool_result, abort_controller)
      end

      def extract_error_from_hash(result)
        inner = result[:result]
        if inner.is_a?(Hash) && inner[:error]
          inner[:error].to_s
        elsif inner.is_a?(String)
          inner
        else
          result.to_s
        end
      end
    end
  end
end
