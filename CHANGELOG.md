## [0.4.0] — 2026-07-17

### Added

- **Agent testing framework** — `Ask::Agent::Test` provides deterministic agent behavior tests without calling real LLMs. Stub tool calls and text responses, assert which tools were called, in what order, and verify the final response. No flaky tests, no API keys, no cost.

  ```ruby
  require "ask/agent/test"

  class MyAgentTest < Minitest::Test
    include Ask::Agent::Test::Assertions

    def setup
      @session = Ask::Agent::Session.new(model: "gpt-4o", tools: [my_tool])
      @session.test_mode
    end

    def test_calls_search_tool
      @session.stub_tool_call("search", query: "weather")
      @session.stub_text("Sunny")
      @session.run("What's the weather?")
      assert_called_tool "search"
      assert_final_response /Sunny/
      assert_no_unused_stubs
    end
  end
  ```

  Assertions: `assert_called_tool`, `refute_called_tool`, `assert_tool_order`, `assert_final_response`, `assert_no_unused_stubs`.

## [0.3.1] — 2026-07-17

### Added

- **Rate-limit aware retry in Chat** — `Chat#ask` retries up to 3 times on `RateLimitError`, using `retry_after` from the error when available, otherwise exponential backoff with jitter.

### Fixed

- **`retryable_error_name?` in ToolExecutor** — fixed duplicate `Ask::RateLimitError` and non-existent `Ask::ServiceUnavailableError`. Now uses class hierarchy matching so subclasses are also retried. (Backport from LiteLLM error classification.)

## [0.3.0] — 2026-07-17

### Added

- **Token and cost tracking** — `ResponseMessage` and `ChatChunk` now carry `input_tokens`, `output_tokens`, and `cost` fields. Token counts are extracted from provider responses and streaming chunks.
- **Instrumentation events** — `Chat#ask` emits `chat.ask` and `chat.stream.ask` events via `Ask::Instrumentation`, unlocking the full monitoring pipeline (ask-agent → ask-instrumentation → ask-monitoring).
- **Cost in agent events** — `SessionEnd` and `TurnEnd` events now include `input_tokens`, `output_tokens`, and `cost` fields, accumulated across all turns in the session.
- **Cumulative session costs** — `Session` tracks `total_input_tokens`, `total_output_tokens`, and `total_cost` across all turns and reflection rounds.

### Changed

- **Dependency added** — `ask-instrumentation >= 0.1` added to gemspec. Instrumentation is optional (emission is wrapped in `defined?` check).
- **Gemfile** — now uses local path resolution for sibling ask-* gems during development.

## [0.2.1] - 2026-06-25

### Changed
- Major test expansion: Session(28t), Chat(32t), Loop(12t), ToolExecutor(10t), Compactor(14t), Reflector(12t), MetaAgent(10t), Telemetry(13t), Events(29t), Extensions(14t), provider stubs. Bugfix: MAX_CONSECUTIVE_TOOL_TURNS -> @max_consecutive_tool_turns. Infrastructure: rubocop, overcommit, CI matrix, gemspec, SimpleCov.
# Changelog

## 0.2.0 (2026-06-21)

- Made `max_consecutive_tool_turns` configurable in `Loop#initialize`
- Improved loop detection with Levenshtein similarity-based matching (80%+ threshold)
- Added `levenshtein_distance` and `levenshtein_ratio` helpers

## 0.1.12

- Various fixes
