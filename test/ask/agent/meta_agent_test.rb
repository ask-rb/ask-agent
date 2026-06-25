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

  def test_generate_report_with_no_results
    report = @agent.generate_report([])
    assert_equal "No improvement opportunities found.", report
  end

  def test_parse_llm_response_with_json_array
    result = @agent.send(:parse_llm_response, '[{"issue": "test"}]')
    assert_equal 1, result.size
    assert_equal "test", result[0]["issue"]
  end

  def test_parse_llm_response_with_malformed_json
    result = @agent.send(:parse_llm_response, "not json")
    assert_equal [], result
  end

  def test_parse_llm_response_with_extra_text
    result = @agent.send(:parse_llm_response, 'Here is the analysis: [{"issue": "test"}]')
    assert_equal 1, result.size
    assert_equal "test", result[0]["issue"]
  end

  def test_parse_llm_response_empty
    result = @agent.send(:parse_llm_response, "[]")
    assert_equal [], result
  end

  def test_track_resolution_invalid_id
    assert_equal false, @agent.track_resolution(nil)
  end

  def test_track_resolution_unknown_id
    @agent.define_singleton_method(:load_source) { {} }
    assert_nil @agent.track_resolution("nonexistent")
  end

  def test_build_result_with_symbol_keys
    result = @agent.send(:build_result, { issue: "Test", file: "test.rb", line: 10, confidence: "high", suggestion: "Fix" })
    assert_equal "Test", result.issue
    assert_equal "test.rb", result.file
    assert_equal 10, result.line
  end

  def test_build_result_with_string_keys
    result = @agent.send(:build_result, { "issue" => "Test", "file" => "test.rb" })
    assert_equal "Test", result.issue
    assert_equal "test.rb", result.file
  end
end
