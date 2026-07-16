# frozen_string_literal: true

require_relative "../../test_helper"
require "ask/agent/test"

class AgentTestFrameworkTest < Minitest::Test
  include Ask::Agent::Test::Assertions

  def setup
    @session = Ask::Agent::Session.new(model: "gpt-4o", tools: [test_tool])
    @session.test_mode
  end

  def teardown
    @session = nil
  end

  def test_stub_text_response
    @session.stub_text("Hello from test")
    response = @session.run("Say hello")
    assert_equal "Hello from test", response
    assert_no_unused_stubs
  end

  def test_stub_tool_call
    @session.stub_tool_call("echo", command: "hello")
    @session.stub_text("Done")

    @session.run("Run echo")
    assert_called_tool "echo"
    assert_final_response /Done/
    assert_no_unused_stubs
  end

  def test_multiple_tool_calls_sequential
    @session.stub_tool_call("echo", command: "first")
    @session.stub_tool_call("echo", command: "second")
    @session.stub_text("All done")

    @session.run("Do both")
    assert_tool_order %w[echo echo]
    assert_final_response /All done/
    assert_no_unused_stubs
  end

  def test_refute_called_tool
    @session.stub_text("Just talking")
    @session.run("Hello")
    refute_called_tool "echo"
    assert_no_unused_stubs
  end

  def test_called_tool_query
    @session.stub_tool_call("echo", command: "hi")
    @session.stub_text("done")
    @session.run("Say hi")
    assert @session.called_tool?("echo")
  end

  def test_unused_stubs_detected
    @session.stub_text("first")
    @session.stub_text("second")
    @session.run("Say first")
    refute_empty @session.test_mode.unused_stubs
  end

  def test_tool_called_tracked_after_run
    @session.stub_tool_call("echo", command: "hello")
    @session.stub_text("done")
    @session.run("test")
    assert_called_tool "echo"
    assert_final_response /done/
  end

  def test_test_mode_methods_available_but_inactive
    session = Ask::Agent::Session.new(model: "gpt-4o", tools: [test_tool])
    refute session.test_mode.called_tools.any?
  end

  private

  def test_tool
    @test_tool ||= begin
      cls = Class.new(Ask::Tool) do
        description "Test echo tool"
        param :command, type: "string", desc: "Command"

        def self.name
          "EchoTool"
        end

        def execute(command:)
          Ask::Result.success("echo: #{command}")
        end
      end
      cls.new
    end
  end
end
