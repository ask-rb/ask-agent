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

## Documentation

### Documentation
- **Update ask-docs** after releasing v0.1.0 — the docs site at github.com/ask-rb/ask-docs must reflect this gems API, usage, and position in the ecosystem.
- The ask-docs repo has a Jekyll site with sections for each gem under core/, providers/, tools/, agent/.
- Add or update the relevant page(s) and submit a PR to ask-docs.
- This is not optional — ask-docs is the public face of the ecosystem.

## Release Checklist (Required for v0.1.0)

Before declaring this gem done and releasing v0.1.0, verify:

- [] All tests pass with >90% coverage
- [] Every public API method has documentation (yardoc or inline comments)
- [] README is complete: installation, quick start, configuration, development
- [] CHANGELOG.md exists with an entry for v0.1.0
- [] All code is committed and pushed to github.com/ask-rb/ask-agent
- [] Gem builds without errors: gem build *.gemspec
- [] Gem is released as a private gem (see guides/RELEASING.md when available)
- [] A consumer app can install, require, and use the gem with no errors
- [] Thread-safety verified (registry, config, client construction)
- [] Error messages are helpful and actionable

## What Done Means for v0.1.0

The gem reaches v0.1.0 when:
- All implementation steps above are complete and tested
- The gem is released on GitHub Packages as a private gem
- A real consumer can install it with gem install or Bundler
- A consumer script can require it and use its full public API
- The README provides enough information for someone unfamiliar to get started in 5 minutes
- The CHANGELOG documents what v0.1.0 delivers

## Development Workflow

### Git conventions
- Follow the git-workflow skill for branch naming, commit messages, and PR structure.
- Use conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`.
- One logical change per commit. No "fixup" or "wip" commits on main.
- Commit messages must be one direct sentence describing the change.

### Reference projects
Study existing implementations for patterns and conventions:

- **ask-tools-shell** — extract from `ruby_llm-conductor/lib/ruby_llm/conductor/tools/`
- **ask-agent** — port from `ruby_llm-conductor/` (session, loop, tool_executor, compactor, etc.)
- **ask-rails** — transform from `solid_agents/` (railtie, generators, persistence)
- **ask-openai, ask-anthropic** — study `ruby_llm/lib/ruby_llm/providers/` for wire formats and streaming patterns
- **ask-openai** — also study `llm-proxy/lib/llm_proxy/protocols/` for OpenAI protocol conversion
- **General patterns** — study `pi/packages/ai/src/providers/` for lazy loading, registration, and protocol families
- **Test patterns** — study `ruby_llm/spec/` for VCR cassette structure and integration testing patterns
- **ask-github** — reference implementation for service context gems; follow its three-file pattern
### Reference Repositories (Local)
All ask-rb gem repos are available locally at /Users/kaka/Code/ask-rb/ for reference.
Do not clone from GitHub — use the local directories:
- Source code: /Users/kaka/Code/ask-rb/GEMNAME/lib/
- Tests: /Users/kaka/Code/ask-rb/GEMNAME/test/
- Goal: /Users/kaka/Code/ask-rb/GEMNAME/GOAL.md
- Gemspec: /Users/kaka/Code/ask-rb/GEMNAME/GEMNAME.gemspec

Other reference projects in the same workspace:
- /Users/kaka/Code/ask-rb/ruby_llm/ — RubyLLM gem (providers, models, streaming)
- /Users/kaka/Code/ask-rb/ruby_llm-conductor/ — Original conductor (agent loop, tools)
- /Users/kaka/Code/ask-rb/llm-proxy/ — Protocol normalization patterns
- /Users/kaka/Code/ask-rb/pi/ — Pi agent (TypeScript, provider architecture)
- /Users/kaka/Code/ask-rb/solid_agents/ — Original solid_agents (Rails engine)
- /Users/kaka/Code/ask-rb/composio/ — Composio SDK (MCP tool execution examples)
- /Users/kaka/Code/ask-rb/ask-docs/ — Documentation site (update after release)

### Testing
- Use Minitest (not RSpec) — consistent with the ask-rb ecosystem.
- Unit tests for every public method (normal path + edge cases + error cases).
- Integration tests with VCR cassettes for any gem that calls external APIs.
- Run the full suite before every commit: `bundle exec rake test`.
