# ask-agent — Agent Runtime

## Purpose

The core agent loop: think → call tools → execute → feed back → repeat. This is the engine every AI agent runs on.

Renamed from `ruby_llm-conductor` (which lives at `github.com/ask-rb/ruby_llm-conductor`). The conductor code becomes the foundation of this gem, ported from `RubyLLM::Conductor` namespace to `Ask::Agent`.

## Dependencies

- **Runtime:**
  - `ask-tools` (provides `Ask::Tool` base class, `Ask::Result`)
  - `ask-tools-shell` (provides execution tools — Bash, Code, etc.)
  - `ruby_llm >= 1.14` (**temporary** — provides `RubyLLM::Chat`, providers, streaming. Will be replaced by `ask-core` + provider gems in Phase 3)
- **Build/test:** minitest, mocha, rake, vcr, webmock
- **This gem MUST wait until `ask-tools` and `ask-tools-shell` are built, tested, and released.**

## Implementation Steps

### 1. Port conductor code to ask namespace
- Copy `lib/ruby_llm/conductor/` → `lib/ask/agent/`
- Rename module: `RubyLLM::Conductor` → `Ask::Agent`
- Update all internal references
- Do NOT copy `tools/` directory (tools live in `ask-tools-shell` now)
- Do NOT copy `providers/` directory (kept in `ruby_llm` temporarily, moved later)
- Keep: `session.rb`, `loop.rb`, `tool_executor.rb`, `compactor.rb`, `hooks.rb`, `events.rb`, `reflector.rb`, `telemetry.rb`, `meta_agent.rb`, `configuration.rb`, `tool_abort_controller.rb`
- Keep: `persistence/base.rb`, `persistence/in_memory.rb`, `persistence/active_record.rb`

### 2. Update the entry point (`lib/ask-agent.rb`)
- Depend on `ask-tools` and `ask-tools-shell` instead of having internal tools
- Require `Ask::Agent` module, configure concurrency, register providers

### 3. Update `Session` to use `Ask::Tools` from gems
- `resolve_tools` should accept `Ask::Tool` instances (any `Ask::Tool` subclass works)
- Tool resolution is interface-based, not namespace-based — no code changes needed

### 4. Adopt concurrent tool result streaming (from ruby_llm 1.16)
- Modify `ToolExecutor#execute_parallel` to feed each result to the chat as it completes
- Accept an `on_result` callback parameter
- Pass the callback from `Loop` which adds the tool result message immediately
- This replaces the current "collect all, then add batch" behavior

### 5. Update error handling
- `retryable_error_name?` — keep current list, add `RubyLLM::ContextLengthExceededError` to retryable set
- Critical error detection — keep current CRITICAL_ERROR_CLASSES

### 6. Write `ask-agent.gemspec`
- Dependencies: `ask-tools`, `ask-tools-shell`, `ruby_llm` (temporary)
- No `ask-auth` dependency (agents don't need auth directly — tools do)

### 7. Test coverage
- Port all existing conductor tests under new namespace
- Update test references from `RubyLLM::Conductor::Tools::*` to `Ask::Tools::*`
- Test `Session#run` creates agent loop, calls LLM, executes tools, returns response
- Test `ToolExecutor` parallel + sequential modes
- Test `Compactor` token estimation and compaction
- Test `Hooks` before/after tool lifecycle
- Test event emission (`SessionStart`, `TurnEnd`, `ToolExecutionStart`, etc.)
- Test persistence (in-memory, ActiveRecord)
- Test concurrent tool result streaming (new)
- Test error recovery (max turns, loop detection, context length exceeded)

### 8. README
- Quick start: `Ask::Agent::Session.new(model:, tools:).run("message")`
- Events system documented with all event types
- Extension system documented
- Configuration options
- Migration guide from `ruby_llm-conductor`

### 9. Production hardening
- Thread safety in concurrent tool execution
- Graceful shutdown on abort
- Memory bounds on conversation history
- Telemetry with sensible defaults that don't log sensitive data
- Error recovery that doesn't retry critical errors (auth, permissions, payment required)

## What "Done" Means

- All conductor code ported to `Ask::Agent` namespace
- Tests pass — all existing conductor tests work under new namespace
- `Session#run` creates a full agent loop with tools from `ask-tools-shell`
- Concurrent tool results stream to chat as each tool finishes
- Persistence (in-memory + ActiveRecord) works
- Hooks and extensions system works
- Events fire correctly throughout the lifecycle
- Compactor manages context window
- >90% test coverage
- `ruby_llm` dependency still in place but clearly marked as temporary
- README has quick start, migration guide, full API docs
