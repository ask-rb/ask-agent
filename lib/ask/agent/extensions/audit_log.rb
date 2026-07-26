# frozen_string_literal: true

require "json"

module Ask
  module Agent
    module Extensions
      # Event-driven audit log for agent sessions.
      #
      # Subscribes to all session events and writes them to a configurable
      # adapter. Ships with an ActiveRecord adapter; custom adapters can
      # implement the simple {Adapter} interface.
      #
      # @example Enable globally (ActiveRecord)
      #   Ask::Agent.configure do |c|
      #     c.audit_log = { adapter: :active_record }
      #   end
      #
      # @example Per-session with custom adapter
      #   Session.new(model: "gpt-4o", audit_log: { adapter: MyWriter.new })
      #
      class AuditLog
        # Pluggable adapter interface.
        # Implement +write(entry)+ to persist a structured event hash.
        class Adapter
          def write(entry)
            raise NotImplementedError
          end
        end

        # Built-in adapter: appends JSON lines to a file.
        class FileAdapter < Adapter
          def initialize(path: "tmp/agent_audit.jsonl")
            @path = path
            @mutex = Mutex.new
          end

          def write(entry)
            @mutex.synchronize do
              File.open(@path, "a") { |f| f.puts(JSON.generate(entry)) }
            end
          end
        end

        # Event types that get persisted (not every delta/stream event).
        STORED_EVENTS = {
          Events::SessionStart       => "session_start",
          Events::SessionEnd         => "session_end",
          Events::TurnEnd            => "turn_end",
          Events::ToolExecutionStart => "tool_execution_start",
          Events::ToolExecutionEnd   => "tool_execution_end",
          Events::Error              => "error",
          Events::MaxTurnsExceeded   => "max_turns_exceeded",
          Events::LoopDetected       => "loop_detected",
          Events::CompactionEnd      => "compaction_end",
          Events::EvaluationBlocked  => "evaluation_blocked"
        }.freeze

        def initialize(session, adapter: nil)
          @session = session
          @session_id = session.id
          @adapter = resolve(adapter)
          subscribe! if @adapter
        end

        # Subscribe to session events and log stored event types.
        def subscribe!
          @session.on_event do |event|
            type = STORED_EVENTS[event.class]
            next unless type

            write_entry(type, extract(event))
          end
        end

        # Legacy hook interface — kept for backward compatibility.
        # Called by the hooks system after each tool execution.
        def after_tool_call(tool_call, result, _context)
          write_entry("tool_call", {
            tool_name: tool_call.name,
            arguments: tool_call.arguments,
            result: result&.to_s&.to_s[0, 500],
            duration_ms: result[:duration_ms]
          })
        end

        private

        def resolve(adapter)
          return nil if adapter.nil?
          return adapter if adapter.is_a?(Adapter)

          case adapter
          when :active_record
            require "ask/agent/extensions/audit_log/active_record_writer"
            AuditLog::ActiveRecordWriter.new
          when Hash
            resolve(adapter[:adapter] || adapter[:writer])
          when Symbol, String
            # Try to load adapter by convention:
            # :active_record → ask/agent/extensions/audit_log/active_record_writer
            name = adapter.to_s
            begin
              require "ask/agent/extensions/audit_log/#{name}_writer"
              klass_name = name.split("_").map(&:capitalize).join
              klass = AuditLog.const_get(klass_name)
              klass.new
            rescue LoadError
              warn "[ask-agent] AuditLog: adapter not found: #{name}"
              nil
            end
          else
            adapter
          end
        rescue LoadError
          warn "[ask-agent] AuditLog: ActiveRecord adapter not available"
          nil
        end

        def write_entry(type, data)
          entry = {
            session_id: @session_id,
            event_type: type,
            timestamp: Time.now.utc.iso8601(3),
            data: data
          }
          @adapter.write(entry)
        rescue => e
          warn "[ask-agent] AuditLog write failed: #{e.message}"
        end

        def extract(event)
          case event
          when Events::SessionStart
            {}
          when Events::SessionEnd
            {
              turn_count: event.turn_count,
              tool_calls_made: event.tool_calls_made,
              input_tokens: event.input_tokens,
              output_tokens: event.output_tokens,
              cost: event.cost
            }
          when Events::TurnEnd
            {
              turn_number: event.turn_number,
              tool_results_count: event.tool_results&.length || 0,
              input_tokens: event.input_tokens,
              output_tokens: event.output_tokens,
              cost: event.cost
            }
          when Events::ToolExecutionStart
            { name: event.name, id: event.id, args: safe_args(event.arguments) }
          when Events::ToolExecutionEnd
            {
              name: event.name, id: event.id,
              duration_ms: event.duration_ms,
              is_error: event.is_error,
              result: event.result&.to_s&.to_s[0, 500]
            }
          when Events::Error
            { message: event.error, recoverable: event.recoverable }
          when Events::MaxTurnsExceeded
            { max_turns: event.max_turns }
          when Events::LoopDetected
            { tool_name: event.tool_name, repeated_count: event.repeated_count }
          when Events::CompactionEnd
            { tokens_before: event.tokens_before, tokens_after: event.tokens_after }
          when Events::EvaluationBlocked
            { feedback: event.feedback, scores: event.scores }
          else
            {}
          end
        end

        def safe_args(args)
          return {} unless args.is_a?(Hash)

          safe = args.dup
          %w[password secret token api_key key auth_token access_token sql command].each do |sensitive|
            safe[sensitive] = "[REDACTED]" if safe.key?(sensitive)
            safe[sensitive.to_sym] = "[REDACTED]" if safe.key?(sensitive.to_sym)
          end
          safe
        end
      end
    end
  end
end
