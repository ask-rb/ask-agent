# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"
require "tmpdir"

class ExtensionsTest < Minitest::Test
  def setup
    @call = OpenStruct.new(name: "write", id: "call_1", arguments: { path: "test.txt" })
  end

  # --- Permissions ---

  def test_permissions_blocks_by_default
    gate = Ask::Agent::Extensions::Permissions.new
    result = gate.before_tool_call(@call, {})
    assert_equal :block, result[:action]
  end

  def test_permissions_allows_safe_tools
    gate = Ask::Agent::Extensions::Permissions.new
    read_call = OpenStruct.new(name: "read", id: "call_2", arguments: {})
    result = gate.before_tool_call(read_call, {})
    assert_equal :proceed, result[:action]
  end

  def test_permissions_approve
    gate = Ask::Agent::Extensions::Permissions.new
    gate.before_tool_call(@call, {})
    assert gate.approve("call_1")
  end

  def test_permissions_approve_unknown_key
    gate = Ask::Agent::Extensions::Permissions.new
    refute gate.approve("nonexistent_call")
  end

  def test_permissions_pending_approvals
    gate = Ask::Agent::Extensions::Permissions.new
    gate.before_tool_call(@call, {})
    pending = gate.pending_approvals
    assert_equal 1, pending.size
    assert_equal "call_1", pending.first[:tool_call].id
  end

  def test_permissions_approved_after_approve
    gate = Ask::Agent::Extensions::Permissions.new
    gate.before_tool_call(@call, {})
    gate.approve("call_1")
    result = gate.__send__(:approved?, @call)
    assert result
  end

  def test_permissions_custom_blocked_tools
    gate = Ask::Agent::Extensions::Permissions.new(blocked_tools: [:read, :write])
    write_call = OpenStruct.new(name: "read", id: "call_3", arguments: {})
    result = gate.before_tool_call(write_call, {})
    assert_equal :block, result[:action]
  end

  def test_permissions_full_access_mode
    gate = Ask::Agent::Extensions::Permissions.new(mode: :full_access)
    result = gate.before_tool_call(@call, {})
    assert_equal :proceed, result[:action]
  end

  def test_permissions_read_only_mode
    gate = Ask::Agent::Extensions::Permissions.new(mode: :read_only)
    result = gate.before_tool_call(@call, {})
    assert_equal :block, result[:action]
  end

  def test_permissions_ask_before_changes_mode
    gate = Ask::Agent::Extensions::Permissions.new(mode: :ask_before_changes)
    result = gate.before_tool_call(@call, {})
    assert_equal :block, result[:action]
  end

  def test_permissions_invalid_mode_raises
    assert_raises(ArgumentError) do
      Ask::Agent::Extensions::Permissions.new(mode: :invalid_mode)
    end
  end

  def test_permissions_loads_via_autoload
    assert Ask::Agent::Extensions::Permissions
  end

  # --- RateLimiter ---

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

  def test_rate_limiter_resets_per_minute_window
    limiter = Ask::Agent::Extensions::RateLimiter.new(max_calls_per_minute: 1)
    limiter.before_tool_call(@call, {})
    # Reset turn to bypass turn limit
    limiter.reset_turn!
    result = limiter.before_tool_call(@call, {})
    assert_equal :block, result[:action]
  end

  # --- AuditLog ---

  def test_audit_log_records_entries
    log = Ask::Agent::Extensions::AuditLog.new(output: StringIO.new)
    log.after_tool_call(@call, { result: "ok", duration_ms: 10 }, {})
    assert_equal 1, log.entries.length
    assert_equal "write", log.entries.first[:tool_name]
  end

  def test_audit_log_writes_to_path
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "audit.log")
      log = Ask::Agent::Extensions::AuditLog.new(path: log_path)
      log.after_tool_call(@call, { result: "ok", duration_ms: 10 }, {})
      assert File.exist?(log_path)
      content = File.read(log_path)
      assert_includes content, "write"
    end
  end

end
