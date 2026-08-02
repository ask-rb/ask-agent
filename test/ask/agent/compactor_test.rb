# frozen_string_literal: true

require_relative "../../test_helper"

class CompactorTest < Minitest::Test
  def setup
    @compactor = Ask::Agent::Compactor.new(threshold: 0.5)
  end

  def build_chat(model: "gpt-4o", messages: [])
    chat = Ask::Agent::Chat.new(model: model)
    messages.each { |m| chat.add_message(**m) }
    chat
  end

  # Register a throwaway model so catalog lookups don't collide with the
  # bundled model JSONs (which include real context/max_output metadata).
  def register_test_model(id, **opts)
    Ask::ModelCatalog.instance.register(
      Ask::ModelInfo.new(id: id, provider: "openai", **opts)
    )
  end

  # --- Token estimation ---

  def test_estimate_tokens
    assert_equal 1, @compactor.estimate_tokens("hi")
  end

  def test_estimate_tokens_empty
    assert_equal 0, @compactor.estimate_tokens("")
  end

  def test_empty_tokens
    assert_equal 0, @compactor.estimate_total_tokens
  end

  def test_estimate_total_tokens_with_messages
    chat = build_chat(messages: [{ role: :user, content: "Hello, world!" }])
    @compactor.chat = chat
    count = @compactor.estimate_total_tokens
    assert count > 0
  end

  # --- Guards ---

  def test_no_chat_should_not_compact
    refute @compactor.should_compact?
  end

  def test_no_chat_run_does_nothing
    @compactor.run
    assert true
  end

  def test_overflow_recovered_defaults_to_false
    refute @compactor.overflow_recovered?
  end

  def test_microcompact_with_empty_chat
    @compactor.microcompact!
    assert true
  end

  def test_should_compact_requires_chat
    refute @compactor.should_compact?
  end

  # --- Context window ---

  def test_context_window_with_chat
    chat = build_chat(model: "gpt-4o")
    @compactor.chat = chat
    assert_equal 128_000, @compactor.context_window
  end

  def test_context_window_falls_back_to_default_when_model_lacks_metadata
    register_test_model("no-window-model")
    chat = build_chat(model: "no-window-model")
    @compactor.chat = chat
    assert_equal 128_000, @compactor.context_window
  end

  def test_context_window_from_model_catalog
    register_test_model("custom-big", context_window: 500_000)
    chat = build_chat(model: "custom-big")
    @compactor.chat = chat
    assert_equal 500_000, @compactor.context_window
  end

  # --- Reserve derivation (Flue-style) ---

  def test_reserve_default_when_model_has_no_max_output
    register_test_model("no-meta-model")
    chat = build_chat(model: "no-meta-model")
    @compactor.chat = chat
    assert_equal Ask::Agent::Compactor::DEFAULT_RESERVE_TOKENS, @compactor.reserve_tokens
  end

  def test_reserve_capped_at_model_max_output
    register_test_model("small-output", context_window: 128_000, max_output_tokens: 4_096)
    chat = build_chat(model: "small-output")
    @compactor.chat = chat
    assert_equal 4_096, @compactor.reserve_tokens
  end

  def test_reserve_uses_default_when_max_output_exceeds_cap
    register_test_model("huge-output", context_window: 200_000, max_output_tokens: 100_000)
    chat = build_chat(model: "huge-output")
    @compactor.chat = chat
    assert_equal Ask::Agent::Compactor::DEFAULT_RESERVE_TOKENS, @compactor.reserve_tokens
  end

  def test_reserve_safety_floor_for_tiny_window
    # reserve would consume >= half the window → clamp to window / 3
    register_test_model("tiny-window", context_window: 30_000, max_output_tokens: 20_000)
    chat = build_chat(model: "tiny-window")
    @compactor.chat = chat
    assert_equal 10_000, @compactor.reserve_tokens
  end

  def test_reserve_safety_floor_minimum
    register_test_model("ultra-tiny", context_window: 2_000, max_output_tokens: 1_000)
    chat = build_chat(model: "ultra-tiny")
    @compactor.chat = chat
    assert_operator @compactor.reserve_tokens, :>=, Ask::Agent::Compactor::MIN_RESERVE_TOKENS
  end

  def test_explicit_reserve_wins
    compactor = Ask::Agent::Compactor.new(reserve_tokens: 5_000)
    chat = build_chat(model: "gpt-4o")
    compactor.chat = chat
    assert_equal 5_000, compactor.reserve_tokens
  end

  # --- Compact threshold ---

  def test_threshold_mode_uses_window_times_threshold
    compactor = Ask::Agent::Compactor.new(threshold: 0.8)
    chat = build_chat(model: "gpt-4o")
    compactor.chat = chat
    assert_equal 102_400, compactor.compact_threshold_tokens
  end

  def test_reserve_mode_uses_window_minus_reserve
    compactor = Ask::Agent::Compactor.new # no threshold → reserve mode
    register_test_model("reserve-model", context_window: 128_000, max_output_tokens: 8_000)
    chat = build_chat(model: "reserve-model")
    compactor.chat = chat
    assert_equal 120_000, compactor.compact_threshold_tokens
  end

  def test_should_compact_false_below_threshold
    chat = build_chat(messages: [{ role: :user, content: "Short" }])
    @compactor.chat = chat
    refute @compactor.should_compact?
  end

  def test_should_compact_true_at_threshold
    compactor = Ask::Agent::Compactor.new(threshold: 0.0001) # tiny threshold
    chat = build_chat(messages: [{ role: :user, content: "a" * 100 }])
    compactor.chat = chat
    assert compactor.should_compact?
  end

  def test_should_compact_reserve_mode_zero_reserve
    compactor = Ask::Agent::Compactor.new(reserve_tokens: 128_000) # trigger at 0 tokens
    chat = build_chat(messages: [{ role: :user, content: "a" * 400 }]) # ~100 tokens
    compactor.chat = chat
    assert compactor.should_compact?
  end

  # --- compact! ---

  def test_compact_requires_at_least_min_messages
    chat = build_chat(messages: Array.new(5) { |i| { role: :user, content: "msg #{i}" } })
    @compactor.chat = chat
    @compactor.compact!
    assert_operator chat.messages.size, :>=, 5
  end

  def test_compact_summarizes_older_and_keeps_recent
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    @compactor.chat = chat
    @compactor.compact!

    # 8 kept (DEFAULT_KEEP_COUNT) + 1 summary appended = 9
    assert_equal 9, chat.messages.size
    summary_msg = chat.messages.find { |m| m.role == :system }
    assert_includes summary_msg.content, "[Previous conversation summary]"
  end

  def test_compact_keeps_recent_token_budget
    compactor = Ask::Agent::Compactor.new(keep_recent_tokens: 100)
    # Each message ~200 chars ≈ 50 tokens; 10 messages = 500 tokens
    messages = Array.new(10) { |i| { role: :user, content: ("word " * 40) + i.to_s } }
    chat = build_chat(messages: messages)
    compactor.chat = chat
    compactor.compact!

    # Budget 100 tokens keeps ~2 by tokens, but MIN_MESSAGES floor keeps 6:
    # 4 summarized + 6 kept + 1 summary = 7
    assert_equal 7, chat.messages.size
  end

  def test_compact_keeps_at_least_min_messages_with_small_budget
    compactor = Ask::Agent::Compactor.new(keep_recent_tokens: 1)
    messages = Array.new(10) { |i| { role: :user, content: ("word " * 40) + i.to_s } }
    chat = build_chat(messages: messages)
    compactor.chat = chat
    compactor.compact!

    # Budget 1 keeps ~0 by tokens, but floor keeps 6: 4 summarized + 6 + 1
    assert_equal 7, chat.messages.size
  end

  def test_compact_with_empty_older_does_nothing
    compactor = Ask::Agent::Compactor.new(keep_recent_tokens: 10_000)
    chat = build_chat(messages: Array.new(6) { |i| { role: :user, content: "tiny #{i}" } })
    compactor.chat = chat
    compactor.compact!
    # Everything fits in the budget → nothing summarized, messages unchanged
    assert_equal 6, chat.messages.size
  end

  # --- microcompact! ---

  def test_microcompact_clears_long_tool_results
    chat = build_chat(messages: [
      { role: :user, content: "run tool" },
      { role: :tool, content: "x" * 500 }
    ])
    @compactor.chat = chat
    @compactor.microcompact!
    tool_msg = chat.messages.find { |m| m.role == :tool }
    assert_equal "[Tool result cleared by compaction]", tool_msg.content
  end

  def test_microcompact_keeps_short_tool_results
    chat = build_chat(messages: [
      { role: :user, content: "run tool" },
      { role: :tool, content: "short result" }
    ])
    @compactor.chat = chat
    @compactor.microcompact!
    tool_msg = chat.messages.find { |m| m.role == :tool }
    assert_equal "short result", tool_msg.content
  end

  def test_microcompact_preserves_tool_call_id
    chat = build_chat(messages: [
      { role: :user, content: "run tool" },
      { role: :tool, content: "x" * 500, tool_call_id: "call_abc" }
    ])
    @compactor.chat = chat
    @compactor.microcompact!
    tool_msg = chat.messages.find { |m| m.role == :tool }
    assert_equal "call_abc", tool_msg.tool_call_id
  end

  # --- recover_from_overflow ---

  def test_recover_from_overflow_compacts_first_time
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    @compactor.chat = chat
    @compactor.recover_from_overflow
    assert @compactor.overflow_recovered?
    assert_operator chat.messages.size, :<, 10
  end

  def test_recover_from_overflow_microcompacts_second_time
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    @compactor.chat = chat

    @compactor.recover_from_overflow
    size_after_first = chat.messages.size

    @compactor.recover_from_overflow
    # Second recovery does not compact again (already compacted) — size stable
    assert_equal size_after_first, chat.messages.size
  end

  # --- Events ---

  def test_run_emits_events
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    @compactor.chat = chat
    events = []
    emitter = Object.new
    emitter.define_singleton_method(:emit) { |e| events << e }
    @compactor.run(event_emitter: emitter)
    assert events.any? { |e| e.is_a?(Ask::Agent::Events::CompactionStart) }
    assert events.any? { |e| e.is_a?(Ask::Agent::Events::CompactionEnd) }
  end

  # --- LLM summary ---

  def test_llm_summary_used_when_llm_provided
    llm = stub(ask: Ask::Agent::ResponseMessage.new(
      content: "AI-generated summary", tool_calls: {}, thinking: nil,
      input_tokens: nil, output_tokens: nil, cost: nil
    ))
    compactor = Ask::Agent::Compactor.new(llm: llm)
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    compactor.chat = chat
    compactor.compact!
    summary_msg = chat.messages.find { |m| m.role == :system }
    assert_includes summary_msg.content, "AI-generated summary"
  end

  def test_llm_summary_falls_back_to_heuristic_on_error
    llm = stub(ask: -> { raise "boom" })
    compactor = Ask::Agent::Compactor.new(llm: llm)
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    compactor.chat = chat
    compactor.compact!
    summary_msg = chat.messages.find { |m| m.role == :system }
    assert_includes summary_msg.content, "[Previous conversation summary]"
    refute_includes summary_msg.content, "AI-generated"
  end

  # --- extract_summary ---

  def test_extract_summary_finds_last_summary
    chat = build_chat(messages: Array.new(10) { |i| { role: :user, content: "message number #{i}" } })
    @compactor.chat = chat
    @compactor.compact!
    assert_includes @compactor.extract_summary, "[Previous conversation summary]"
  end

  def test_extract_summary_empty_when_none
    chat = build_chat(messages: [{ role: :user, content: "hello" }])
    @compactor.chat = chat
    assert_equal "", @compactor.extract_summary
  end
end
