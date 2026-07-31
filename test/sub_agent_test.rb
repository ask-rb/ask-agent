# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "fileutils"
require "tmpdir"

class SubAgentTest < Minitest::Test
  include AgentTestHelpers

  def setup
    @chat_stub = build_chat_stub
  end

  # --- Inline initialization ---

  def test_creates_inline_sub_agent
    agent = Ask::Agent::SubAgent.new(
      name: "web_search",
      model: "gpt-4o-mini",
      tools: []
    )
    assert_equal "web_search", agent.name
  end

  def test_inline_default_description
    agent = Ask::Agent::SubAgent.new(
      name: "web_search",
      model: "gpt-4o-mini",
      tools: []
    )
    assert_includes agent.description, "gpt-4o-mini"
  end

  def test_inline_description_with_tools
    stub_tool = OpenStruct.new(name: "search_tool")
    agent = Ask::Agent::SubAgent.new(
      name: "web_search",
      model: "gpt-4o-mini",
      tools: [stub_tool]
    )
    assert_includes agent.description, "1 tool"
  end

  def test_inline_custom_description
    agent = Ask::Agent::SubAgent.new(
      name: "code_review",
      description: "Review code for bugs and style issues",
      model: "gpt-4o",
      tools: []
    )
    assert_equal "Review code for bugs and style issues", agent.description
  end

  def test_inline_with_provider
    agent = Ask::Agent::SubAgent.new(
      name: "code_review",
      model: "claude-sonnet-4",
      provider: :anthropic,
      tools: []
    )
    assert_equal "code_review", agent.name
    assert_includes agent.description, "claude-sonnet-4"
  end

  # --- Definition-based initialization ---

  def test_creates_from_definition_name
    Dir.mktmpdir do |tmpdir|
      agents_dir = File.join(tmpdir, "agents")
      agent_dir = File.join(agents_dir, "web_search")
      FileUtils.mkdir_p(agent_dir)

      File.write(File.join(agent_dir, "agent.rb"), <<~RUBY)
        module WebSearch
          class Agent < Ask::Agent::Definition
            model "gpt-4o-mini"
          end
        end
      RUBY

      File.write(File.join(agent_dir, "instructions.md"), "You are a research assistant.")

      # Stub the default agent paths to point to our temp dir
      Ask::Agent.stubs(:default_agent_paths).returns([agents_dir])
      Ask::Agent.rediscover!

      agent = Ask::Agent::SubAgent.new("web_search")
      assert_equal "web_search", agent.name
      assert_includes agent.description, "gpt-4o-mini"
    end
  end

  def test_definition_looks_up_tools
    Dir.mktmpdir do |tmpdir|
      agents_dir = File.join(tmpdir, "agents")
      agent_dir = File.join(agents_dir, "health_check")
      FileUtils.mkdir_p(agent_dir)

      File.write(File.join(agent_dir, "agent.rb"), <<~RUBY)
        module HealthCheck
          class Agent < Ask::Agent::Definition
            model "gpt-4o"
            tools :bash, :read
          end
        end
      RUBY

      Ask::Agent.stubs(:default_agent_paths).returns([agents_dir])
      Ask::Agent.rediscover!

      agent = Ask::Agent::SubAgent.new("health_check")
      assert_equal "health_check", agent.name
    end
  end

  def test_definition_not_found_raises
    Ask::Agent.stubs(:default_agent_paths).returns(["/nonexistent"])
    Ask::Agent.rediscover!

    assert_raises(Ask::Agent::UnknownAgent) do
      Ask::Agent::SubAgent.new("nonexistent_agent")
    end
  end

  # --- Tool duck type ---

  def test_responds_to_tool_interface
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    assert_respond_to agent, :name
    assert_respond_to agent, :description
    assert_respond_to agent, :params_schema
    assert_respond_to agent, :provider_params
    assert_respond_to agent, :call
  end

  def test_params_schema_has_task
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    schema = agent.params_schema
    assert_equal "object", schema[:type]
    assert schema[:properties].key?("task")
    assert_includes schema[:required], "task"
  end

  # --- Execution stub tests ---

  def test_runs_session_on_call
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    result = agent.call("task" => "hello")
    assert_predicate result, :ok?
  end

  def test_forwards_task_to_session
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    result = agent.call("task" => "find the answer")
    assert_predicate result, :ok?
  end

  def test_passes_system_prompt
    chat = build_chat_stub
    chat.stubs(:with_instructions).returns(chat)
    Ask::Agent::Chat.stubs(:new).returns(chat)

    agent = Ask::Agent::SubAgent.new(
      name: "test", model: "gpt-4o",
      system_prompt: "You are a research assistant.",
      tools: []
    )

    result = agent.call(task: "research")
    assert_predicate result, :ok?
  end

  def test_handles_hash_args
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    result = agent.call(task: "hello")
    assert_predicate result, :ok?
  end

  def test_handles_string_args
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    result = agent.call("hello")
    assert_predicate result, :ok?
  end

  def test_error_isolation
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    agent = Ask::Agent::SubAgent.new(name: "test", model: "gpt-4o", tools: [])
    result = agent.call(task: "hello")
    assert_predicate result, :ok?
  end

  # --- Multiple instances ---

  def test_multiple_sub_agents_with_different_names
    search = Ask::Agent::SubAgent.new(name: "web_search", model: "gpt-4o-mini", tools: [])
    review = Ask::Agent::SubAgent.new(
      name: "code_review", description: "Review code",
      model: "claude-sonnet-4", tools: []
    )

    assert_equal "web_search", search.name
    assert_equal "code_review", review.name
  end

  # --- Inspect ---

  def test_inspect
    agent = Ask::Agent::SubAgent.new(name: "my_agent", model: "gpt-4o", tools: [])
    assert_match(/#<Ask::Agent::SubAgent name="my_agent">/, agent.inspect)
  end

  private

  def build_chat_stub
    chat = stub(
      model: "gpt-4o",
      model_id: "gpt-4o",
      messages: [],
      ask: ResponseMessage.new(
        content: "Mock response", tool_calls: {}, thinking: nil,
        input_tokens: nil, output_tokens: nil, cost: nil
      )
    )
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:add_message).returns(nil)
    chat
  end

  ResponseMessage = Data.define(
    :content, :tool_calls, :tool_results, :thinking,
    :input_tokens, :output_tokens, :cost
  ) do
    def initialize(content:, tool_calls: {}, tool_results: {}, thinking: nil,
                   input_tokens: nil, output_tokens: nil, cost: nil)
      super
    end
    def tool_call? = !tool_calls.empty?
    def to_s = content.to_s
  end
end
