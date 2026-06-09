# frozen_string_literal: true

module Ask
  module Agent
    module Extensions
      class AuditLog
        def initialize(output: $stdout, path: nil)
          @entries = []
          @mutex = Mutex.new

          if path
            @io = File.open(path, "a")
            @io.sync = true
          else
            @io = output
          end
        end

        def after_tool_call(tool_call, result, _context)
          entry = {
            timestamp: Time.now.utc.iso8601(3),
            tool_name: tool_call.name,
            arguments: tool_call.arguments,
            result: result,
            duration: result[:duration_ms]
          }

          @mutex.synchronize do
            @entries << entry
            @io.puts entry.to_json
          end

          nil
        end

        def entries
          @mutex.synchronize { @entries.dup }
        end
      end
    end
  end
end
