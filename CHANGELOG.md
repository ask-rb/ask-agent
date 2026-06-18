# Changelog

## 0.1.0 (2026-06-09)

### Added

- `Ask::Agent` — agent runtime with session, loop, tool execution, compaction, hooks, events, and telemetry
- Ported from `RubyLLM::Conductor` to `Ask::Agent` namespace
- `Session` — full agent loop with tool execution, reflection, and meta-agent analysis
- `Loop` — turn management with loop detection, max-turn guard, consecutive tool-turn limit
- `ToolExecutor` — parallel and sequential execution with retry, abort, and critical error detection
- `Compactor` — proactive and overflow compaction for context window management
- `Hooks` — before/after tool lifecycle with block, short-circuit, and transform actions
- `Events` — 18 Data.define event types for streaming, monitoring, and debugging
- `Telemetry` — file-backed telemetry with error tracking, session counting, and recommendations
- `Reflector` — optional LLM-based self-evaluation of assistant responses
- `MetaAgent` — self-improvement system that analyzes telemetry and suggests code changes
- `Configuration` — global configuration with sensible defaults
- Extensions: PermissionGate, RateLimiter, AuditLog
- Persistence: Base, InMemory (ActiveRecord adapter deferred to ask-rails)
- Dependencies: ask-tools, ask-tools-shell, ruby_llm (temporary)

## 0.1.12 (2026-06-18)

### Fixed

- **`lib/ask/agent.rb` requires `ask-tools` directly** — `require "ask/agent"` loaded
  `lib/ask/agent.rb` which required `ask-llm-providers` but NOT `ask-tools`. Users who
  did `require "ask/agent"` (instead of `require "ask-agent"`) got `NameError:
  uninitialized constant Ask::Tool` when using `Ask::Agent::Chat` (which references
  `Ask::Tool` internally). Both entry points now require `ask-tools`:
  `ask-agent.rb` (gem entry) already had it, `ask/agent.rb` (module entry) was
  missing it.
