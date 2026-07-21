# frozen_string_literal: true

require_relative "../../test_helper"

class AgentDefinitionTest < Minitest::Test
  def setup
    # Create a temporary agent directory for testing file-based features
    @tmpdir = Dir.mktmpdir("agent_test")
    @agent_dir = File.join(@tmpdir, "test_agent")
    FileUtils.mkdir_p(@agent_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_model_setter_and_getter
    cls = Class.new(Ask::Agent::Definition)
    cls.model "gpt-4o"
    assert_equal "gpt-4o", cls._config[:model]
  end

  def test_model_defaults_to_nil
    cls = Class.new(Ask::Agent::Definition)
    assert_nil cls._config[:model]
  end

  def test_provider_setter_and_getter
    cls = Class.new(Ask::Agent::Definition)
    cls.provider :opencode_go
    assert_equal :opencode_go, cls._config[:provider]
  end

  def test_max_turns_setter_and_getter
    cls = Class.new(Ask::Agent::Definition)
    cls.max_turns 30
    assert_equal 30, cls._config[:max_turns]
  end

  def test_parallel_tools_setter
    cls = Class.new(Ask::Agent::Definition)
    cls.parallel_tools false
    assert_equal false, cls._config[:parallel_tools]
  end

  def test_parallel_tools_defaults_to_true
    cls = Class.new(Ask::Agent::Definition)
    assert_equal true, cls.parallel_tools
  end

  def test_tools_setter
    cls = Class.new(Ask::Agent::Definition)
    cls.tools :bash, :read
    assert_equal [:bash, :read], cls._config[:tools]
  end

  def test_tools_defaults_to_empty
    cls = Class.new(Ask::Agent::Definition)
    assert_equal [], cls._config[:tools]
  end

  def test_schedule_setter
    cls = Class.new(Ask::Agent::Definition)
    cls.schedule "every 5 minutes"
    assert_equal "every 5 minutes", cls._config[:schedule]
  end

  def test_option_setter_and_getter
    cls = Class.new(Ask::Agent::Definition)
    cls.option :temperature, 0.7
    assert_equal 0.7, cls._config[:options][:temperature]
  end

  def test_multiple_options
    cls = Class.new(Ask::Agent::Definition)
    cls.option :temperature, 0.7
    cls.option :reflector, true
    cls.option :telemetry, false
    assert_equal 0.7, cls._config[:options][:temperature]
    assert_equal true, cls._config[:options][:reflector]
    assert_equal false, cls._config[:options][:telemetry]
  end

  def test_instructions_path_returns_nil_without_dir
    cls = Class.new(Ask::Agent::Definition)
    assert_nil cls.instructions_path
  end

  def test_instructions_path_returns_nil_without_file
    cls = Class.new(Ask::Agent::Definition)
    cls._config[:dir] = @agent_dir
    assert_nil cls.instructions_path
  end

  def test_instructions_path_finds_file
    File.write(File.join(@agent_dir, "instructions.md"), "You are a test agent.")
    cls = Class.new(Ask::Agent::Definition)
    cls._config[:dir] = @agent_dir
    assert_equal File.join(@agent_dir, "instructions.md"), cls.instructions_path
  end

  def test_instructions_content_reads_file
    File.write(File.join(@agent_dir, "instructions.md"), "You are a test agent.")
    cls = Class.new(Ask::Agent::Definition)
    cls._config[:dir] = @agent_dir
    assert_equal "You are a test agent.", cls.instructions_content
  end

  def test_inherited_detects_agent_rb
    agent_rb = File.join(@agent_dir, "agent.rb")
    File.write(agent_rb, "class TestAgent < Ask::Agent::Definition\nend")

    require agent_rb
    cls = Ask::Agent::Definition.subclasses.find { |s| s._config[:dir] == @agent_dir }
    assert cls, "Definition subclass should be registered"
    assert_equal @agent_dir, cls._config[:dir]
  end

  def test_subclasses_track_all_definitions
    count = Ask::Agent::Definition.subclasses.size
    Class.new(Ask::Agent::Definition)
    assert_equal count + 1, Ask::Agent::Definition.subclasses.size
  end
end
