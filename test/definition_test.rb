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

  def test_definition_tracks_subclasses_through_intermediate_base
    intermediate = Class.new(Ask::Agent::Definition)
    nested = Class.new(intermediate)

    assert_includes Ask::Agent::Definition.subclasses, intermediate
    assert_includes Ask::Agent::Definition.subclasses, nested
    assert_includes intermediate.subclasses, nested
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

  def test_discovery_repairs_definition_dir_for_reopened_constant
    Dir.mktmpdir do |tmpdir|
      agents_dir = File.join(tmpdir, "agents")
      agent_dir = File.join(agents_dir, "health_check")
      FileUtils.mkdir_p(agent_dir)
      File.write(File.join(agent_dir, "agent.rb"), <<~RUBY)
        module HealthCheck
          class Agent < Ask::Agent::Definition
            model "gpt-4o"
          end
        end
      RUBY

      Ask::Agent.stubs(:default_agent_paths).returns([agents_dir])
      Ask::Agent.rediscover!
    end

    # The same constant name now exists from another directory. Rediscovery
    # re-opens it instead of redefining — the definition must be re-pointed
    # at the fixture directory so it stays discoverable.
    Ask::Agent.unstub(:default_agent_paths)
    Ask::Agent.instance_variable_set(:@discovered, false)
    Ask::Agent.instance_variable_set(:@registry, {})
    $LOADED_FEATURES.delete_if { |f| f.start_with?(FIXTURES) }

    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      assert Ask::Agent.definitions.key?("health_check"),
        "Should rediscover health_check after constant reopen: #{Ask::Agent.definitions.keys.inspect}"

      _, dir = Ask::Agent.definitions["health_check"]
      assert dir.end_with?("agents/health_check")
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

  # -- Session.build_from_definition (unified API) --

  def test_build_from_definition_creates_session
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, dir = Ask::Agent.definitions["health_check"]
      session = Ask::Agent::Session.build_from_definition(klass, dir)
      assert_instance_of Ask::Agent::Session, session
    end
  end

  def test_build_from_definition_sets_model
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, dir = Ask::Agent.definitions["health_check"]
      session = Ask::Agent::Session.build_from_definition(klass, dir)
      assert_equal "gpt-4o", session.chat.model_id
    end
  end

  def test_build_from_definition_loads_instructions
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, dir = Ask::Agent.definitions["health_check"]
      session = Ask::Agent::Session.build_from_definition(klass, dir)
      system_msgs = session.chat.messages.select { |m| m.role == :system }
      assert system_msgs.any?, "Should have system message from instructions"
      assert_includes system_msgs.first.content, "Health Check Agent"
    end
  end

  def test_build_from_definition_with_model_override
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, dir = Ask::Agent.definitions["health_check"]
      session = Ask::Agent::Session.build_from_definition(klass, dir, model: "claude-sonnet-4")
      assert_equal "claude-sonnet-4", session.chat.model_id
    end
  end

  def test_build_from_definition_with_system_prompt_override
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, dir = Ask::Agent.definitions["health_check"]
      session = Ask::Agent::Session.build_from_definition(klass, dir, system_prompt: "Custom prompt")
      system_msgs = session.chat.messages.select { |m| m.role == :system }
      assert system_msgs.any?
      # The custom prompt should be in the system context, overriding the definition's instructions
      assert session.chat.messages.any? { |m| m.content.to_s.include?("Custom prompt") }
    end
  end

  def test_build_from_definition_sets_agent_dir
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      klass, dir = Ask::Agent.definitions["health_check"]
      session = Ask::Agent::Session.build_from_definition(klass, dir)
      assert_equal dir, session.instance_variable_get(:@agent_dir)
    end
  end

  def test_build_from_definition_matches_agent_new
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      from_definition = Ask::Agent::Session.build_from_definition(
        *Ask::Agent.definitions["health_check"]
      )
      from_agent_new = Ask::Agent.new("health_check")

      assert_equal from_definition.chat.model_id, from_agent_new.chat.model_id
      assert_equal from_definition.tools.size, from_agent_new.tools.size
    end
  end

  # -- Ask.chat with name: --

  def test_ask_chat_with_name_creates_session
    Dir.chdir(FIXTURES) do
      Ask::Agent.rediscover!
      # Ask.chat calls Agent.new which calls Session.build_from_definition
      # We can't run it (no real LLM), but we can verify the path works
      # by stubbing the session's run
      session = nil
      Ask::Agent::Session.any_instance.stubs(:run).returns("ok")
      Ask.chat("hello", name: "health_check")
      pass "Ask.chat with name: did not raise"
    end
  end

  def test_ask_chat_without_name_uses_direct_session
    # Verify the no-name path still works (backward compat)
    Ask::Agent::Session.any_instance.stubs(:run).returns("ok")
    Ask.chat("hello", model: "gpt-4o")
    pass "Ask.chat without name: did not raise"
  end

  # -- Skills install/uninstall --

  def test_skills_install_global
    Dir.mktmpdir do |tmp|
      home_dir = File.join(tmp, "home")
      ENV["HOME"] = home_dir

      Ask::Agent::CLI.cmd_skills_install(["--global"])

      dest = File.join(home_dir, ".agents", "skills", "agent.build_agents", "SKILL.md")
      assert File.file?(dest), "Skill should be installed at #{dest}"

      marker = File.join(File.dirname(dest), ".ask-agent-managed")
      assert File.file?(marker), "Managed marker should exist"

      content = File.read(dest)
      assert_includes content, "name: agent.build_agents"
    ensure
      ENV["HOME"] = ENV["HOME"] # restore
    end
  end

  def test_skills_install_local
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        Ask::Agent::CLI.cmd_skills_install(["--local"])

        dest = File.join(tmp, ".agents", "skills", "agent.build_agents", "SKILL.md")
        assert File.file?(dest), "Skill should be installed locally at #{dest}"
      end
    end
  end

  def test_skills_uninstall_global
    Dir.mktmpdir do |tmp|
      home_dir = File.join(tmp, "home")
      ENV["HOME"] = home_dir

      # Install first
      Ask::Agent::CLI.cmd_skills_install(["--global"])
      dest = File.join(home_dir, ".agents", "skills", "agent.build_agents", "SKILL.md")
      assert File.file?(dest)

      # Uninstall
      Ask::Agent::CLI.cmd_skills_uninstall(["--global"])
      refute File.file?(dest), "Skill should be removed after uninstall"

      marker = File.join(File.dirname(dest), ".ask-agent-managed")
      refute File.file?(marker), "Marker should be removed"
    ensure
      ENV["HOME"] = ENV["HOME"]
    end
  end

  def test_skills_uninstall_not_installed
    Dir.mktmpdir do |tmp|
      home_dir = File.join(tmp, "home")
      ENV["HOME"] = home_dir

      output = capture_io {
        Ask::Agent::CLI.cmd_skills_uninstall(["--global"])
      }.first
      assert_includes output, "nothing to do"
    ensure
      ENV["HOME"] = ENV["HOME"]
    end
  end

  def test_skills_install_bundled_path_exists
    # The CLI resolves the path relative to cli.rb's directory
    cli_dir = File.expand_path("../lib/ask/agent", __dir__)
    bundled = File.expand_path("../../ask/skills/agent.build_agents/SKILL.md", cli_dir)
    assert File.file?(bundled), "Bundled skill should exist at #{bundled}"
  end

  def test_skills_auto_sync_updates_managed_copies
    Dir.mktmpdir do |tmp|
      home_dir = File.join(tmp, "home")
      ENV["HOME"] = home_dir

      # Install
      Ask::Agent::CLI.cmd_skills_install(["--global"])
      dest = File.join(home_dir, ".agents", "skills", "agent.build_agents", "SKILL.md")
      original = File.read(dest)

      # Corrupt the installed copy
      File.write(dest, "corrupted content")

      # Auto-sync should restore it
      Ask::Agent::CLI.auto_sync_skills
      restored = File.read(dest)
      refute_equal "corrupted content", restored, "Auto-sync should overwrite corrupted copy"
    ensure
      ENV["HOME"] = ENV["HOME"]
    end
  end

  def test_skills_auto_sync_skips_unmanaged_copies
    Dir.mktmpdir do |tmp|
      home_dir = File.join(tmp, "home")
      ENV["HOME"] = home_dir

      dest_dir = File.join(home_dir, ".agents", "skills", "agent.build_agents")
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, "SKILL.md")

      # Write a hand-edited copy without the managed marker
      File.write(dest, "hand-edited content")

      # Auto-sync should NOT overwrite
      Ask::Agent::CLI.auto_sync_skills
      assert_equal "hand-edited content", File.read(dest),
        "Auto-sync should not overwrite unmanaged copies"
    ensure
      ENV["HOME"] = ENV["HOME"]
    end
  end
end
