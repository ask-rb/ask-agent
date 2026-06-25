if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    add_filter "/vendor/"
    track_files "lib/**/*.rb"
  end
end

# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-tools/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-tools-shell/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-schema/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-skills/lib", __dir__)

require "ask/version"
require "ask/tools/tool"
require "ask/tools"
require "ask/tools/shell"
require "ask/skills"
require "ask/agent"

require "minitest/autorun"
require "ostruct"
require "mocha/minitest"

module AgentTestHelpers
  # Create a mock chat-like object that responds like Ask::Agent::Chat
  def stub_chat(model: "gpt-4o", messages: [])
    chat = stub(
      model: model,
      model_id: model,
      messages: messages,
      ask: Ask::Agent::ResponseMessage.new(content: "Mock response", tool_calls: {}, thinking: nil)
    )
    chat
  end

  # Create a mock tool call hash (as used internally by Chat/Loop)
  def stub_tool_call(id: "call_1", name: "test_tool", arguments: '{"foo":"bar"}')
    Ask::Agent::ToolCallInfo.new(id: id, name: name, arguments: arguments)
  end

  # Create a mock provider response chunk
  def stub_chunk(content: nil, tool_calls: nil, finish_reason: nil, thinking: nil)
    Ask::Chunk.new(content: content, tool_calls: tool_calls, finish_reason: finish_reason, thinking: thinking)
  end

  # Create a stub tool for testing
  def stub_tool(name: "test_tool", description: "A test tool")
    tool = stub(name: name, description: description)
    tool
  end

  # Create a minimal event emitter for testing
  def stub_event_emitter
    emitter = stub
    emitter
  end
end
