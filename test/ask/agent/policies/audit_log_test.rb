# frozen_string_literal: true

require_relative "../../../test_helper"
require "ostruct"

module Ask
  module Agent
    module Policies
      class AuditLogTest < Minitest::Test
        include AgentTestHelpers

        def setup
          Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
          @session = Ask::Agent::Session.new(model: "gpt-4o", tools: [], max_turns: 1)
          @events = []
        end

        # --- Adapter contract ---

        def test_file_adapter_writes_entries
          Dir.mktmpdir do |dir|
            path = File.join(dir, "audit.jsonl")
            adapter = AuditLog::FileAdapter.new(path: path)
            adapter.write({ session_id: "s1", event_type: "test", data: {}, timestamp: Time.now.iso8601 })
            lines = File.readlines(path)
            assert_equal 1, lines.length
          end
        end

        # --- Event subscription ---

        def test_audit_log_subscribes_to_session_events
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)

          @session.emit(Events::SessionStart.new)
          @session.emit(Events::SessionEnd.new(
            result: "done", turn_count: 1, tool_calls_made: 0,
            input_tokens: 10, output_tokens: 10, cost: 0.0
          ))

          assert_operator store.entries.length, :>=, 1
          types = store.entries.map { |e| e[:event_type] }
          assert_includes types, "session_end"
        end

        def test_audit_log_records_tool_execution
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)

          @session.emit(Events::ToolExecutionStart.new(
            name: "test_tool", arguments: { foo: "bar" }, id: "call_1"
          ))
          @session.emit(Events::ToolExecutionEnd.new(
            name: "test_tool", id: "call_1", result: "ok",
            is_error: false, duration_ms: 100
          ))

          assert_operator store.entries.length, :>=, 1
          start_entry = store.entries.find { |e| e[:event_type] == "tool_execution_start" }
          assert start_entry
          assert_equal "test_tool", start_entry.dig(:data, :name)
        end

        def test_audit_log_records_errors
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)

          @session.emit(Events::Error.new(error: "API timeout", recoverable: true))

          err_entry = store.entries.find { |e| e[:event_type] == "error" }
          assert err_entry
          assert_includes err_entry.dig(:data, :message), "API timeout"
        end

        def test_filters_out_non_stored_events
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)

          @session.emit(Events::TextDelta.new(content: "hello"))
          @session.emit(Events::TurnStart.new)

          assert_empty store.entries
        end

        # --- Adapter resolution ---

        def test_skips_when_adapter_not_found
          log = AuditLog.new(@session, adapter: :nonexistent_adapter)
          assert_nil log.instance_variable_get(:@adapter)
        end

        def test_accepts_custom_adapter
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)
          refute_nil log
        end

        # --- Config integration ---

        def test_session_builds_audit_log_from_parameter
          Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
          store = TestAdapter.new
          session = Ask::Agent::Session.new(model: "gpt-4o", tools: [], audit_log: { adapter: store })
          assert session.instance_variable_get(:@audit_log), "audit_log should be initialized"
        end

        def test_session_uses_global_config
          Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
          Ask::Agent.configure do |c|
            c.audit_log = { adapter: :file }
          end

          session = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
          log = session.instance_variable_get(:@audit_log)
          assert log, "audit_log should be initialized from global config"

          # Reset
          Ask::Agent.configuration.audit_log = nil
        end

        def test_no_audit_log_by_default
          Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
          session = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
          log = session.instance_variable_get(:@audit_log)
          assert_nil log, "audit_log should be nil when not configured"
        end

        # --- Full session run integration ---

        def test_full_session_run_records_session_events
          store = TestAdapter.new
          Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("mock response")

          session = Ask::Agent::Session.new(
            model: "gpt-4o", tools: [], max_turns: 1,
            audit_log: { adapter: store }
          )
          session.run("test message")

          types = store.entries.map { |e| e[:event_type] }
          assert_includes types, "session_start", "session_start should be logged"
          assert_includes types, "session_end", "session_end should be logged"
          assert_operator store.entries.length, :>=, 2, "At least 2 events logged"
        end

        def test_full_session_run_with_tool_records_no_errors
          store = TestAdapter.new
          Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("mock response")

          tool = build_test_tool
          session = Ask::Agent::Session.new(
            model: "gpt-4o", tools: [tool], max_turns: 2,
            audit_log: { adapter: store }
          )
          session.run("use the tool")

          errors = store.entries.select { |e| e[:event_type] == "error" }
          assert_empty errors, "No errors should be logged for a successful run"
          assert store.entries.any? { |e| e[:event_type] == "session_end" },
                 "session_end should be present"
        end

        # --- Legacy hook interface ---

        def test_legacy_after_tool_call
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)

          tool_call = OpenStruct.new(name: "legacy_tool", arguments: '{"input":"test"}')
          log.after_tool_call(tool_call, { duration_ms: 50, message: "ok" }, {})

          entry = store.entries.find { |e| e[:event_type] == "tool_call" }
          assert entry
          assert_equal "legacy_tool", entry.dig(:data, :tool_name)
        end

        # --- Safe args ---

        def test_redacts_sensitive_args
          store = TestAdapter.new
          log = AuditLog.new(@session, adapter: store)

          @session.emit(Events::ToolExecutionStart.new(
            name: "run_sql", arguments: { sql: "SELECT * FROM users", query: "safe" }, id: "call_2"
          ))
          @session.emit(Events::ToolExecutionEnd.new(
            name: "run_sql", id: "call_2", result: "ok", is_error: false, duration_ms: 50
          ))

          entry = store.entries.find { |e| e[:event_type] == "tool_execution_start" }
          assert entry
          assert_equal "[REDACTED]", entry.dig(:data, :args, :sql)
          assert_equal "safe", entry.dig(:data, :args, :query)
        end

        private

        def build_test_tool
          cls = Class.new(Ask::Tool) do
            description "Test tool"
            param :input, type: :string, desc: "Input"

            def execute(input:)
              Ask::Result.success("processed: #{input}")
            end

            def self.name
              "TestTool"
            end
          end
          cls.new
        end

        def build_chat_stub
          model_stub = OpenStruct.new(id: "gpt-4o", to_s: "gpt-4o")
          chat_stub = OpenStruct.new(model: model_stub, model_id: "gpt-4o")
          msgs = []
          chat_stub.define_singleton_method(:with_instructions) { |*| chat_stub }
          chat_stub.define_singleton_method(:add_message) { |role:, content: nil, **| msgs << OpenStruct.new(role: role, content: content, tool_calls: nil) }
          chat_stub.define_singleton_method(:messages) { msgs }
          chat_stub.define_singleton_method(:reset_messages!) { msgs.clear }
          chat_stub
        end
      end

      # In-memory adapter for testing
      class TestAdapter < AuditLog::Adapter
        attr_reader :entries

        def initialize
          @entries = []
        end

        def write(entry)
          @entries << entry
        end
      end
    end
  end
end
