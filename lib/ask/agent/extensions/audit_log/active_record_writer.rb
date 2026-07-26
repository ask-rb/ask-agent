# frozen_string_literal: true

module Ask
  module Agent
    module Extensions
      class AuditLog
        # ActiveRecord adapter for the audit log.
        # Requires the +ask_audit_logs+ table to exist. Generate the migration:
        #
        #   rails generate ask_rails:install
        #
        # Or create it manually (see migration template in ask-rails).
        class ActiveRecordWriter < Adapter
          TABLE_NAME = "ask_audit_logs"

          def initialize
            @table_checked = false
            @mutex = Mutex.new
          end

          def write(entry)
            return unless defined?(ActiveRecord::Base)
            return unless table_ready?

            conn = ActiveRecord::Base.connection
            conn.execute(
              "INSERT INTO #{TABLE_NAME} (session_id, event_type, data, timestamp, created_at, updated_at) " \
              "VALUES (#{quote(entry[:session_id])}, #{quote(entry[:event_type])}, " \
              "#{quote(entry[:data].to_json)}, #{quote(entry[:timestamp])}, " \
              "#{quote(Time.now.utc.iso8601(3))}, #{quote(Time.now.utc.iso8601(3))})"
            )
          rescue ActiveRecord::ActiveRecordError => e
            warn "[ask-agent] AuditLog::ActiveRecordWriter write failed: #{e.message}"
          end

          private

          def table_ready?
            return true if @table_checked

            @mutex.synchronize do
              return true if @table_checked

              conn = ActiveRecord::Base.connection
              if conn.table_exists?(TABLE_NAME)
                @table_checked = true
              else
                warn "[ask-agent] AuditLog: table '#{TABLE_NAME}' does not exist. " \
                     "Run `rails generate ask_rails:install` to create it, " \
                     "or use a different AuditLog adapter (e.g. FileAdapter)."
                @table_checked = true # Don't warn on every write
              end
              @table_checked
            end
          end

          def quote(value)
            ActiveRecord::Base.connection.quote(value)
          end
        end
      end
    end
  end
end
