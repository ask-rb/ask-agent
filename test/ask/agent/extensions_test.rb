# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class ExtensionsTest < Minitest::Test
  def setup
    @call = OpenStruct.new(name: "write", id: "call_1", arguments: { path: "test.txt" })
  end

  def test_permission_gate_blocks_by_default
    gate = Ask::Agent::Extensions::PermissionGate.new
    result = gate.before_tool_call(@call, {})
    assert_equal :block, result[:action]
  end

  def test_permission_gate_allows_safe_tools
    gate = Ask::Agent::Extensions::PermissionGate.new
    read_call = OpenStruct.new(name: "read", id: "call_2", arguments: {})
    result = gate.before_tool_call(read_call, {})
    assert_equal :proceed, result[:action]
  end

  def test_permission_gate_approve
    gate = Ask::Agent::Extensions::PermissionGate.new
    gate.before_tool_call(@call, {})
    assert gate.approve("call_1")
  end

  def test_rate_limiter_allows_first_calls
    limiter = Ask::Agent::Extensions::RateLimiter.new(max_calls_per_minute: 10, max_tool_calls_per_turn: 5)
    result = limiter.before_tool_call(@call, {})
    assert_equal :proceed, result[:action]
  end

  def test_rate_limiter_turn_limit
    limiter = Ask::Agent::Extensions::RateLimiter.new(max_tool_calls_per_turn: 1)
    limiter.before_tool_call(@call, {})
    result = limiter.before_tool_call(@call, {})
    assert_equal :block, result[:action]
  end

  def test_rate_limiter_reset_turn
    limiter = Ask::Agent::Extensions::RateLimiter.new(max_tool_calls_per_turn: 1)
    limiter.before_tool_call(@call, {})
    limiter.reset_turn!
    result = limiter.before_tool_call(@call, {})
    assert_equal :proceed, result[:action]
  end

  def test_audit_log_records_entries
    log = Ask::Agent::Extensions::AuditLog.new(output: StringIO.new)
    log.after_tool_call(@call, { result: "ok", duration_ms: 10 }, {})
    assert_equal 1, log.entries.length
    assert_equal "write", log.entries.first[:tool_name]
  end
end
