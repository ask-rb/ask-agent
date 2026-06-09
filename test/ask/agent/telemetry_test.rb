# frozen_string_literal: true

require_relative "../../test_helper"

class TelemetryTest < Minitest::Test
  def setup
    @telemetry = Ask::Agent::Telemetry.new(enabled: false)
  end

  def test_disabled_log_does_nothing
    @telemetry.log(:tool_error, session_id: "s1", tool_name: "test")
    assert @telemetry.read.empty?
  end

  def test_disabled_session_count_returns_zero
    assert_equal 0, @telemetry.session_count
  end

  def test_disabled_increment_does_nothing
    @telemetry.increment_session_count!
    assert_equal 0, @telemetry.session_count
  end
end
