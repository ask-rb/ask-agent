# frozen_string_literal: true

require_relative "../../test_helper"

class MetaAgentTest < Minitest::Test
  def setup
    @telemetry = Ask::Agent::Telemetry.new(enabled: false)
    @agent = Ask::Agent::MetaAgent.new(telemetry: @telemetry, model: "gpt-4o")
  end

  def test_analyze_with_no_data
    results = @agent.analyze
    assert_equal [], results
  end
end
