# frozen_string_literal: true

require_relative "../../test_helper"
require "tmpdir"

class TelemetryTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("telemetry_test")
    @telemetry = Ask::Agent::Telemetry.new(enabled: true, dir: @tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_disabled_log_does_nothing
    t = Ask::Agent::Telemetry.new(enabled: false, dir: @tmpdir)
    t.log(:tool_error, session_id: "s1", tool_name: "test")
    assert_equal({}, t.read)
  end

  def test_disabled_session_count_returns_zero
    t = Ask::Agent::Telemetry.new(enabled: false, dir: @tmpdir)
    assert_equal 0, t.session_count
  end

  def test_disabled_increment_does_nothing
    t = Ask::Agent::Telemetry.new(enabled: false, dir: @tmpdir)
    t.increment_session_count!
    assert_equal 0, t.session_count
  end

  def test_log_writes_event_file
    @telemetry.log(:tool_error, session_id: "s1", tool_name: "get_weather", error_class: "Timeout::Error")
    data = @telemetry.read
    assert data.key?("tool_error")
    assert_equal 1, data["tool_error"].size
    assert_equal "s1", data["tool_error"].first["session_id"]
  end

  def test_log_filters_unknown_event_types
    @telemetry.log(:unknown_event, session_id: "s1")
    assert_equal({}, @telemetry.read)
  end

  def test_read_empty_directory
    t = Ask::Agent::Telemetry.new(enabled: true, dir: "/tmp/nonexistent_telemetry_#{SecureRandom.hex(8)}")
    assert_equal({}, t.read)
  end

  def test_session_counter
    assert_equal 0, @telemetry.session_count
    @telemetry.increment_session_count!
    assert_equal 1, @telemetry.session_count
    @telemetry.increment_session_count!
    assert_equal 2, @telemetry.session_count
  end

  def test_reset_session_counter
    @telemetry.increment_session_count!
    @telemetry.reset_session_count!
    assert_equal 0, @telemetry.session_count
  end

  def test_clear_removes_all_files
    @telemetry.log(:tool_error, session_id: "s1")
    @telemetry.log(:loop_detected, session_id: "s1")
    @telemetry.clear!
    assert_equal({}, @telemetry.read)
  end

  def test_track_recommendation
    rec_id = @telemetry.track_recommendation(issue: "Test issue", file: "test.rb", line: 1, confidence: "high", suggestion: "Fix it")
    assert rec_id
    assert rec_id.start_with?("rec_")
  end

  def test_read_recommendations
    @telemetry.track_recommendation(issue: "Issue 1", file: "a.rb", line: 1, confidence: "high", suggestion: "Fix")
    recs = @telemetry.read_recommendations
    assert_equal 1, recs.size
    assert_equal "open", recs.first["status"]
  end

  def test_track_resolution
    rec_id = @telemetry.track_recommendation(issue: "Issue", file: "a.rb", line: 1, confidence: "high", suggestion: "Fix")
    assert @telemetry.track_resolution(rec_id)
    recs = @telemetry.read_recommendations(status: "open")
    assert recs.empty?
  end

  def test_read_recommendations_by_status
    rec_id = @telemetry.track_recommendation(issue: "Issue", file: "a.rb", line: 1, confidence: "high", suggestion: "Fix")
    open_recs = @telemetry.read_recommendations(status: "open")
    assert_equal 1, open_recs.size
    resolved_recs = @telemetry.read_recommendations(status: "resolved")
    assert resolved_recs.empty?
  end
end
