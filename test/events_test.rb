# frozen_string_literal: true

require_relative "test_helper"

class EventsTest < Minitest::Test
  def test_session_start_event
    event = Ask::Agent::Events::SessionStart.new
    assert_instance_of Ask::Agent::Events::SessionStart, event
  end

  def test_session_end_event
    event = Ask::Agent::Events::SessionEnd.new(result: "done", turn_count: 5, tool_calls_made: 3)
    assert_equal "done", event.result
    assert_equal 5, event.turn_count
    assert_equal 3, event.tool_calls_made
  end

  def test_text_delta_event
    event = Ask::Agent::Events::TextDelta.new(content: "Hello")
    assert_equal "Hello", event.content
  end

  def test_text_delta_with_empty_content
    event = Ask::Agent::Events::TextDelta.new(content: "")
    assert_equal "", event.content
  end

  def test_tool_call_delta_event
    event = Ask::Agent::Events::ToolCallDelta.new(name: "get_weather", arguments: '{"city":"London"}', id: "call_1")
    assert_equal "get_weather", event.name
    assert_equal "call_1", event.id
    assert_equal '{"city":"London"}', event.arguments
  end

  def test_tool_execution_start_event
    event = Ask::Agent::Events::ToolExecutionStart.new(name: "search", arguments: { q: "test" }, id: "call_2")
    assert_equal "search", event.name
    assert_equal "call_2", event.id
    assert_equal({ q: "test" }, event.arguments)
  end

  def test_tool_execution_update_event
    event = Ask::Agent::Events::ToolExecutionUpdate.new(name: "bash", id: "call_3", partial_result: { output: "in progress" })
    assert_equal "bash", event.name
    assert_equal({ output: "in progress" }, event.partial_result)
  end

  def test_tool_execution_end_event
    event = Ask::Agent::Events::ToolExecutionEnd.new(
      name: "test_tool", id: "call_1", result: { output: "ok" },
      is_error: false, duration_ms: 100
    )
    assert_equal "test_tool", event.name
    assert_equal "call_1", event.id
    refute event.is_error
    assert_equal 100, event.duration_ms
  end

  def test_tool_execution_end_with_error
    event = Ask::Agent::Events::ToolExecutionEnd.new(
      name: "failing_tool", id: "call_4", result: { error: "timeout" },
      is_error: true, duration_ms: 5000
    )
    assert event.is_error
    assert_equal 5000, event.duration_ms
  end

  def test_message_start_event
    event = Ask::Agent::Events::MessageStart.new
    assert_instance_of Ask::Agent::Events::MessageStart, event
  end

  def test_message_end_event
    event = Ask::Agent::Events::MessageEnd.new(tool_calls: true)
    assert event.tool_calls
    event2 = Ask::Agent::Events::MessageEnd.new(tool_calls: false)
    refute event2.tool_calls
  end

  def test_turn_start_event
    event = Ask::Agent::Events::TurnStart.new
    assert_instance_of Ask::Agent::Events::TurnStart, event
  end

  def test_turn_end_event
    results = [{ tool_name: "test", message: "done", status: "success" }]
    event = Ask::Agent::Events::TurnEnd.new(tool_results: results, turn_number: 3)
    assert_equal results, event.tool_results
    assert_equal 3, event.turn_number
  end

  def test_turn_end_with_empty_results
    event = Ask::Agent::Events::TurnEnd.new(tool_results: [], turn_number: 1)
    assert_empty event.tool_results
  end

  def test_compaction_start_event
    event = Ask::Agent::Events::CompactionStart.new(tokens_before: 100_000, reason: :threshold)
    assert_equal 100_000, event.tokens_before
    assert_equal :threshold, event.reason
  end

  def test_compaction_start_with_overflow_reason
    event = Ask::Agent::Events::CompactionStart.new(tokens_before: 200_000, reason: :overflow)
    assert_equal :overflow, event.reason
  end

  def test_compaction_end_event
    event = Ask::Agent::Events::CompactionEnd.new(tokens_before: 100_000, tokens_after: 50_000, summary: "compacted conversation")
    assert_equal 100_000, event.tokens_before
    assert_equal 50_000, event.tokens_after
    assert_equal "compacted conversation", event.summary
  end

  def test_loop_detected_event
    event = Ask::Agent::Events::LoopDetected.new(tool_name: "get_weather", repeated_count: 3)
    assert_equal "get_weather", event.tool_name
    assert_equal 3, event.repeated_count
  end

  def test_max_turns_exceeded_event
    event = Ask::Agent::Events::MaxTurnsExceeded.new(max_turns: 25)
    assert_equal 25, event.max_turns
  end

  def test_reflection_start_event
    event = Ask::Agent::Events::ReflectionStart.new(reflection_number: 1)
    assert_equal 1, event.reflection_number
  end

  def test_reflection_delta_event
    event = Ask::Agent::Events::ReflectionDelta.new(content: "Checking accuracy...")
    assert_equal "Checking accuracy...", event.content
  end

  def test_reflection_end_event
    event = Ask::Agent::Events::ReflectionEnd.new(decision: :deliver, feedback: nil)
    assert_equal :deliver, event.decision
    assert_nil event.feedback
  end

  def test_reflection_end_with_feedback
    event = Ask::Agent::Events::ReflectionEnd.new(decision: :improve, feedback: "add more detail")
    assert_equal :improve, event.decision
    assert_equal "add more detail", event.feedback
  end

  def test_meta_agent_analysis_event
    results = [{ issue: "test", file: "test.rb", line: 10 }]
    event = Ask::Agent::Events::MetaAgentAnalysis.new(results: results, count: 1)
    assert_equal results, event.results
    assert_equal 1, event.count
  end

  def test_meta_agent_analysis_empty
    event = Ask::Agent::Events::MetaAgentAnalysis.new(results: [], count: 0)
    assert_empty event.results
    assert_equal 0, event.count
  end

  def test_error_event
    event = Ask::Agent::Events::Error.new(error: "Connection failed", recoverable: true)
    assert_equal "Connection failed", event.error
    assert event.recoverable
  end

  def test_error_event_non_recoverable
    event = Ask::Agent::Events::Error.new(error: "Fatal", recoverable: false)
    refute event.recoverable
  end

  def test_all_event_types_exist
    types = Ask::Agent::Events.constants
    expected_types = %i[SessionStart SessionEnd TurnStart TurnEnd MessageStart
                        TextDelta ToolCallDelta MessageEnd ToolExecutionStart
                        ToolExecutionUpdate ToolExecutionEnd CompactionStart
                        CompactionEnd LoopDetected MaxTurnsExceeded
                        ReflectionStart ReflectionDelta ReflectionEnd
                        MetaAgentAnalysis Error]
    expected_types.each { |t| assert types.include?(t), "#{t} should be an event type" }
  end

  def test_all_event_types_are_data_defines
    types = Ask::Agent::Events.constants.map { |c| Ask::Agent::Events.const_get(c) }
    data_types = types.select { |t| t.is_a?(Class) && t.ancestors.include?(Data) }
    assert_equal types.size, data_types.size, "All event types should be Data.define"
  end
end
