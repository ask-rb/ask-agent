# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < Minitest::Test
  def test_default_values
    config = Ask::Agent::Configuration.new
    assert_equal "gpt-4o", config.default_model
    assert_equal 25, config.default_max_turns
    assert_equal true, config.compactor_enabled
    assert_equal 0.8, config.compactor_threshold
    assert_equal true, config.parallel_tool_execution
    assert_equal 3, config.max_tool_retries
  end

  def test_configurable
    Ask::Agent.configure do |c|
      c.default_model = "claude-sonnet-4"
      c.default_max_turns = 50
    end
    assert_equal "claude-sonnet-4", Ask::Agent.configuration.default_model
    assert_equal 50, Ask::Agent.configuration.default_max_turns
  end
end
