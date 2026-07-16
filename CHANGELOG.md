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
