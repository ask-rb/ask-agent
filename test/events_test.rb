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

  def test_tool_execution_end_event
    event = Ask::Agent::Events::ToolExecutionEnd.new(
      name: "test_tool", id: "call_1", result: { output: "ok" },
      is_error: false, duration_ms: 100
    )
    assert_equal "test_tool", event.name
    assert_equal "call_1", event.id
  end

  def test_compaction_events
    start = Ask::Agent::Events::CompactionStart.new(tokens_before: 100_000, reason: :threshold)
    assert_equal 100_000, start.tokens_before

    finish = Ask::Agent::Events::CompactionEnd.new(tokens_before: 100_000, tokens_after: 50_000, summary: "compacted")
    assert_equal 50_000, finish.tokens_after
  end

  def test_loop_detected_event
    event = Ask::Agent::Events::LoopDetected.new(tool_name: "get_weather", repeated_count: 3)
    assert_equal "get_weather", event.tool_name
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
end
