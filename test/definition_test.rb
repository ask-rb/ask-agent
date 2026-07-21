# frozen_string_literal: true

require_relative "test_helper"

class DefinitionTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  TEMP_PREFIX = "ask-agent-test-"

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "claude-sonnet-4", provider: "anthropic"))

    # Reset registry for clean discovery each test
    Ask::Agent.instance_variable_set(:@discovered, false)
    Ask::Agent.instance_variable_set(:@registry, {})

    # Clear loaded features from fixtures and temp dirs
    $LOADED_FEATURES.delete_if { |f| f.start_with?(FIXTURES) }
  end

  def teardown
    Ask::Agent::Scheduler.stop
    Ask::Agent.configuration.instance_variable_set(:@scheduler_config,
      Ask::Agent::SchedulerConfig.new(Ask::Agent.configuration))
  end

  # -- Definition base class --

  def test_definition_tracks_subclasses
    subclass = Class.new(Ask::Agent::Definition)
    assert_includes Ask::Agent::Definition.subclasses, subclass
  end

  def test_definition_model
    subclass = Class.new(Ask::Agent::Definition) { model "gpt-4o" }
    assert_equal "gpt-4o", subclass.model
  end

  def test_definition_tools
    subclass = Class.new(Ask::Agent::Definition) { tools :bash, :read }
    assert_equal [:bash, :read], subclass.tools
  end

  def test_definition_schedule
    subclass = Class.new(Ask::Agent::Definition) { schedule "0 9 * * 1-5" }
    assert_equal "0 9 * * 1-5", subclass.schedule
  end

  def test_definition_no_model_returns_nil
    subclass = Class.new(Ask::Agent::Definition)
    assert_nil subclass.model
  end

  def test_definition_no_tools_returns_empty
    subclass = Class.new(Ask::Agent::Definition)
    assert_equal [], subclass.tools
  end

  # -- Discovery --

  def test_discovers_agents_from_agents_dir
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      defs = Ask::Agent.definitions
      assert defs.key?("health_check"), "Should discover health_check"
      assert defs.key?("daily_report"), "Should discover daily_report"
    end
  end

  def test_discovers_agents_from_app_agents_dir
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      defs = Ask::Agent.definitions
      assert defs.key?("rails_bot"), "Should discover rails_bot from app/agents/"
    end
  end

  def test_discovery_finds_all_agents
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      assert_equal 3, Ask::Agent.definitions.length
    end
  end

  def test_definition_has_directory
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      _, dir = Ask::Agent.definitions["health_check"]
      assert dir.end_with?("agents/health_check")
    end
  end

  # -- Instructions --

  def test_loads_instructions_from_md_file
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, _dir = Ask::Agent.definitions["health_check"]
      content = klass.instructions_content
      assert content
      assert_includes content, "Health Check Agent"
    end
  end

  def test_instructions_path_for_agent_without_md
    Dir.mktmpdir do |tmp|
      dir = File.join(tmp, "agents", "no_instructions")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "agent.rb"), <<~RUBY)
        class NoInstructions < Ask::Agent::Definition
          model "gpt-4o"
        end
      RUBY

      Dir.chdir(tmp) do
        Ask::Agent.rediscover!
        klass, _dir = Ask::Agent.definitions["no_instructions"]
        assert_nil klass.instructions_path
        assert_nil klass.instructions_content
      end
    end
  end

  # -- Ask::Agent.new --

  def test_new_creates_session
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      session = Ask::Agent.new("health_check")
      assert_instance_of Ask::Agent::Session, session
    end
  end

  def test_new_sets_model
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      session = Ask::Agent.new("health_check")
      assert_equal "gpt-4o", session.chat.model_id
    end
  end

  def test_new_sets_system_prompt_from_instructions
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      session = Ask::Agent.new("health_check")
      system_msgs = session.chat.messages.select { |m| m.role == :system }
      assert system_msgs.any?, "Should have system message from instructions"
      assert_includes system_msgs.first.content, "Health Check Agent"
    end
  end

  def test_new_for_agent_without_instructions
    Dir.mktmpdir do |tmp|
      dir = File.join(tmp, "agents", "no_instructions")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "agent.rb"), <<~RUBY)
        class NoInstructionsAgent < Ask::Agent::Definition
          model "gpt-4o"
        end
      RUBY

      Dir.chdir(tmp) do
        Ask::Agent.rediscover!
        session = Ask::Agent.new("no_instructions")
        system_msgs = session.chat.messages.select { |m| m.role == :system }
        assert_equal 0, system_msgs.length, "Should have no system message"
      end
    end
  end

  def test_new_raises_for_unknown_agent
    assert_raises(Ask::Agent::UnknownAgent) {
      Ask::Agent.new("nonexistent")
    }
  end

  # -- Configuration from definition --

  def test_daily_report_has_correct_config
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, _dir = Ask::Agent.definitions["daily_report"]
      assert_equal "claude-sonnet-4", klass.model
      assert_equal [:bash, :grep], klass.tools
      assert_equal "0 9 * * 1-5", klass.schedule
    end
  end

  def test_rails_bot_from_app_agents
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, _dir = Ask::Agent.definitions["rails_bot"]
      assert_equal "gpt-4o", klass.model
      assert_equal [:read, :grep], klass.tools
    end
  end

  # -- Schedule registration --

  def test_defining_schedule_registers_with_scheduler
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!

      # Creating a session for an agent with schedule should register it
      Ask::Agent.new("daily_report")

      scheduler_config = Ask::Agent.configuration.scheduler
      tasks = []
      scheduler_config.each_task { |t| tasks << t }
      assert tasks.any?, "Should have registered a scheduler task"
      assert_equal :every, tasks.last[:type]
    end
  end

  # -- CLI command tests --

  def test_cli_list_output
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!

      output = capture_io {
        Ask::Agent::CLI.cmd_list
      }.first

      assert_includes output, "health_check"
      assert_includes output, "daily_report"
      assert_includes output, "rails_bot"
    end
  end

  def test_cli_new_creates_agent_directory
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        Ask::Agent::CLI.cmd_new(["test_bot"])

        assert File.directory?("agents/test_bot")
        assert File.exist?("agents/test_bot/agent.rb")
        assert File.exist?("agents/test_bot/instructions.md")

        agent_rb = File.read("agents/test_bot/agent.rb")
        assert_includes agent_rb, "class TestBot < Ask::Agent::Definition"
        assert_includes agent_rb, "Ask::Agent::Definition"
      end
    end
  end
end
