# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/vcr_config"

# Integration tests for Ask::Agent::SubAgent that make real API calls.
#
# These tests use VCR to record and replay HTTP interactions. On first run
# with API keys set, they record the cassettes. Subsequent runs replay them.
#
# To run:
#   bundle exec ruby -Itest test/sub_agent_integration_test.rb
#
# To re-record cassettes, delete them first:
#   rm -rf test/fixtures/vcr_cassettes/sub_agent_integration/
class SubAgentIntegrationTest < Minitest::Test
  include AgentTestHelpers

  def setup
    @chat_stub = build_chat_stub
  end

  # Tests that use the echo tool (no API calls needed)
  def test_sub_agent_delegates_to_echo_tool
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)

    search = Ask::Agent::SubAgent.new(
      name: "echo_agent",
      model: "gpt-4o",
      system_prompt: "You are an echo.",
      tools: []
    )

    coordinator = Ask::Agent::Session.new(
      model: "gpt-4o",
      tools: [search]
    )

    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    result = coordinator.run("Say hello")
    assert result.to_s.length > 0
  end

  # VCR-recorded test: SubAgent runs a real LLM call
  # Tests that the SubAgent tool creates a session and gets a response.
  # Requires OPENCODE_API_KEY or OPENCODE_GO_API_KEY in the environment.
  # Cassettes are recorded on first run and replayed on subsequent runs
  # for speed and deterministic results.
  def test_sub_agent_runs_real_llm
    skip "Set OPENCODE_GO_API_KEY to run" unless ENV["OPENCODE_GO_API_KEY"]

    VCR.use_cassette("sub_agent_integration/simple_llm") do
      sub = Ask::Agent::SubAgent.new(
        name: "greeter",
        description: "A friendly greeter",
        model: "deepseek-v4-flash",
        provider: :opencode_go,
        tools: [],
        system_prompt: "You are a friendly assistant. Keep responses very brief."
      )

      result = sub.call(task: "Say hello in one word")
      assert_predicate result, :ok?
      assert result.output.to_s.length > 0, "Expected non-empty result from sub-agent"
    end
  end

  # VCR-recorded test: SubAgent from definition with real LLM
  def test_sub_agent_from_definition_calls_real_llm
    skip "Set OPENCODE_GO_API_KEY to run" unless ENV["OPENCODE_GO_API_KEY"]

    VCR.use_cassette("sub_agent_integration/from_definition") do
      Dir.mktmpdir do |tmpdir|
        agents_dir = File.join(tmpdir, "agents")
        agent_dir = File.join(agents_dir, "greeter")
        FileUtils.mkdir_p(agent_dir)

        File.write(File.join(agent_dir, "agent.rb"), <<~RUBY)
          class GreeterAgent < Ask::Agent::Definition
            model "deepseek-v4-flash"
            provider :opencode_go
          end
        RUBY
        File.write(File.join(agent_dir, "instructions.md"),
                   "You are a friendly greeter. Always start with 'Hello!'")

        Ask::Agent.stubs(:default_agent_paths).returns([agents_dir])
        Ask::Agent.rediscover!

        greeter = Ask::Agent::SubAgent.new("greeter")

        result = greeter.call(task: "Greet me")
        assert_predicate result, :ok?
        assert result.output.to_s.length > 0, "Expected non-empty result from definition-based sub-agent"
      end
    end
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
