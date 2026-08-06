# frozen_string_literal: true
require "time"

module Ask
  module Agent
    module Policies
      class AuditLog
        # ActiveRecord adapter for the audit log.
        # Auto-creates the +ask_audit_logs+ table on first write using
        # CREATE TABLE IF NOT EXISTS, so it works with or without Rails
        # migrations. Rails users can also run:
        #
        #   rails generate ask_rails:install
        #
        # to get a proper migration file. The migration uses
        # +if_not_exists: true+ so it won't conflict with auto-creation.
        class ActiveRecordWriter < Adapter
          TABLE_NAME = "ask_audit_logs"

          def initialize
            @table_checked = false
            @mutex = Mutex.new
          end

          def write(entry)
            return unless defined?(ActiveRecord::Base)

            ensure_table!
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

          def ensure_table!
            return if @table_checked

            @mutex.synchronize do
              return if @table_checked
              conn = ActiveRecord::Base.connection
              unless conn.table_exists?(TABLE_NAME)
                conn.create_table(TABLE_NAME, if_not_exists: true) do |t|
                  t.string :session_id, null: false
                  t.string :event_type, null: false
                  t.jsonb :data, default: {}
                  t.datetime :timestamp, null: false
                  t.timestamps

                  t.index [:session_id, :event_type]
                  t.index :timestamp
                end
              end
              @table_checked = true
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
