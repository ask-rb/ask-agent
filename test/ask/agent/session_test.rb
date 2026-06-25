# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class SessionTest < Minitest::Test
  include AgentTestHelpers

  def setup
    @chat_stub = build_chat_stub
  end

  # --- Initialization ---

  def test_create_session
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    assert s.id
    assert_instance_of String, s.id
    refute s.running?
    refute s.deleted?
    assert_equal 0, s.turn_count
  end

  def test_session_with_tools
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    tool = OpenStruct.new(name: "test_tool")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [tool])
    assert s.tools.any?
  end

  def test_session_id_custom
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], id: "custom-id")
    assert_equal "custom-id", s.id
  end

  def test_session_with_nil_telemetry
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], telemetry: false)
    refute s.instance_variable_get(:@telemetry).enabled
  end

  def test_session_with_max_tool_retries
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], max_tool_retries: 5)
    executor = s.instance_variable_get(:@tool_executor)
    assert_equal 5, executor.instance_variable_get(:@max_retries)
  end

  def test_session_with_parallel_tools_false
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], parallel_tools: false)
    executor = s.instance_variable_get(:@tool_executor)
    refute executor.instance_variable_get(:@parallel)
  end

  def test_session_with_reflector_true
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], reflector: true)
    refute_nil s.instance_variable_get(:@reflector)
  end

  def test_session_with_reflector_hash
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], reflector: { max_reflections: 3 })
    reflector = s.instance_variable_get(:@reflector)
    refute_nil reflector
    assert_equal 3, reflector.instance_variable_get(:@max_reflections)
  end

  def test_created_at_is_time
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    assert_instance_of Time, s.created_at
  end

  # --- Abort ---

  def test_abort
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    refute s.abort_requested?
    s.abort
    assert s.abort_requested?
  end

  # --- Guards ---

  def test_deleted_session_prevents_run
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.delete
    assert s.deleted?
    assert_raises(RuntimeError) { s.run("hello") }
  end

  def test_run_raises_if_already_running
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.instance_variable_set(:@running, true)
    assert_raises(RuntimeError) { s.run("hello") }
  end

  # --- Events ---

  def test_on_event_registers_handler
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.on_event { |e| }
    assert s.instance_variable_get(:@event_handlers)[:all].any?
  end

  def test_on_typed_event_registers_handler
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.on(Ask::Agent::Events::SessionStart) { }
    assert s.instance_variable_get(:@event_handlers).key?(Ask::Agent::Events::SessionStart)
  end

  def test_emit_dispatches_to_handlers
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    received = []
    s.on(Ask::Agent::Events::SessionStart) { |e| received << e }
    s.emit(Ask::Agent::Events::SessionStart.new)
    assert_equal 1, received.size
  end

  # --- Run flow: exceptions ---

  def test_max_turns_exceeded_returns_last_content
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).raises(Ask::Agent::MaxTurnsExceeded)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.chat.add_message(role: :assistant, content: "Final response before timeout")
    result = s.run("hello")
    assert_equal "Final response before timeout", result
  end

  def test_loop_detected_returns_last_content
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).raises(Ask::Agent::LoopDetected.new("get_weather"))
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.chat.add_message(role: :assistant, content: "Recovered from loop")
    result = s.run("hello")
    assert_equal "Recovered from loop", result
  end

  def test_context_length_exceeded_without_compactor
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).raises(Ask::ContextLengthExceeded)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    result = s.run("hello")
    assert_includes result, "conversation has grown too long"
  end

  # --- Run flow: event emission ---

  def test_run_emits_session_start
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    events = []
    s.on(Ask::Agent::Events::SessionStart) { |e| events << e }
    s.run("hello")
    assert events.any?
  end

  def test_run_emits_session_end
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    events = []
    s.on(Ask::Agent::Events::SessionEnd) { |e| events << e }
    s.run("hello")
    assert events.any?
  end

  def test_run_stores_messages_after_completion
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.run("hello")
    assert_instance_of Array, s.messages
  end

  def test_run_resets_running_flag
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.run("hello")
    refute s.running?
  end

  def test_run_tool_calls_made_after_run
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.run("hello")
    assert_equal 0, s.tool_calls_made
  end

  def test_run_reset_messages
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.reset_messages!
    assert_equal [], s.chat.messages
  end

  def test_no_tools_instructed_message
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    s.run("hello")
    assert s.instance_variable_get(:@_no_tools_instructed)
  end

  # --- Reflection ---

  def test_reflection_count_after_run
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    Ask::Agent::Loop.any_instance.stubs(:run_turn).returns("response")
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], reflector: true)
    s.run("hello")
    assert_equal 0, s.reflection_count
  end

  # --- Skill ---

  def test_skill_not_found_raises
    Ask::Agent::Chat.stubs(:new).returns(@chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    assert_raises(Ask::Skills::Error) { s.skill("nonexistent_skill") }
  end

  private

  def build_chat_stub
    model_stub = OpenStruct.new(id: "gpt-4o", to_s: "gpt-4o")
    chat_stub = OpenStruct.new(model: model_stub, model_id: "gpt-4o")
    msgs = []
    chat_stub.define_singleton_method(:with_instructions) { |*| chat_stub }
    chat_stub.define_singleton_method(:add_message) { |role:, content: nil, **| msgs << OpenStruct.new(role: role, content: content, tool_calls: nil) }
    chat_stub.define_singleton_method(:messages) { msgs }
    chat_stub.define_singleton_method(:reset_messages!) { msgs.clear }
    chat_stub
  end
end
