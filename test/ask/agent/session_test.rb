# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class SessionTest < Minitest::Test
  def test_create_session
    RubyLLM::Chat.stubs(:new).returns(stub_llm)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], max_turns: 10)
    assert s.id
  end

  def test_abort
    RubyLLM::Chat.stubs(:new).returns(stub_llm)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    refute s.abort_requested?
    s.abort
    assert s.abort_requested?
  end

  private

  def stub_llm
    model_stub = OpenStruct.new(id: "gpt-4o", to_s: "gpt-4o")
    chat_stub = OpenStruct.new(model: model_stub)
    chat_stub.define_singleton_method(:with_instructions) { |*| chat_stub }
    chat_stub.define_singleton_method(:add_message) { |*| }
    chat_stub.define_singleton_method(:messages) { [] }
    chat_stub.define_singleton_method(:with_tools) { |*| }
    chat_stub
  end
end
