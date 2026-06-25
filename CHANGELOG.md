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
