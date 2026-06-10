# ask-agent — Agent Runtime

## Purpose

The core agent loop: think → call tools → execute → feed back → repeat. This is the engine every AI agent runs on.

Renamed from `ruby_llm-conductor` (which lives at `github.com/ask-rb/ruby_llm-conductor`). The conductor code becomes the foundation of this gem, ported from `RubyLLM::Conductor` namespace to `Ask::Agent`.

## Dependencies

- **Runtime:**
  - `ask-tools` (provides `Ask::Tool` base class, `Ask::Result`)
  - `ask-tools-shell` (provides execution tools — Bash, Code, etc.)
  - `ask-core` `ask-llm-providers` (provides `Ask::Provider`, streaming)
- **Build/test:** minitest, mocha, rake, vcr, webmock
- **This gem MUST wait until `ask-tools` and `ask-tools-shell` are built, tested, and released.**

## Implementation Steps

### 1. Port conductor code to ask namespace
- Copy `lib/ruby_llm/conductor/` → `lib/ask/agent/`
- Rename module: `RubyLLM::Conductor` → `Ask::Agent`
- Update all internal references
- Do NOT copy `tools/` directory (tools live in `ask-tools-shell` now)
- Do NOT copy `providers/` directory (handled by `ask-llm-providers`)
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
- `retryable_error_name?` — keep current list, add `Ask::ContextLengthExceeded` to retryable set
- Critical error detection — keep current CRITICAL_ERROR_CLASSES

### 6. Write `ask-agent.gemspec`
- Dependencies: `ask-core`, `ask-llm-providers`, `ask-tools`, `ask-tools-shell`
- No `ask-auth` dependency (agents don't need auth directly — tools do)
- **Migration complete:** `ruby_llm` dependency removed. `Ask::Agent::Chat` wraps `Ask::Provider` for LLM calls.

### 7. Test coverage
### 8. Build built-in safety extensions
The following extensions ship with ask-agent as opt-in safety modules:

**PermissionGate** — Require approval before destructive operations:
- Hooks into `before_tool_call`
- Configurable tool list: `:write`, `:edit`, `:bash`, `:destroy`, etc.
- Configurable timeout (approval expires after N seconds)
- Can block execution entirely or require confirmation

**RateLimiter** — Prevent runaway tool calls:
- `max_calls_per_minute` (default: 20)
- `max_tool_calls_per_turn` (default: 5)
- If exceeded, the agent is told to stop and reassess

**AuditLog** — Immutable record of every tool call:
- Append-only log to file or stdout
- Records: timestamp, tool name, arguments, result, duration, session_id
- No modification or deletion — pure append

### 9. Port opencode providers
The conductor previously registered `opencode` and `opencode_go` providers through ruby_llm.
These must be ported to ask-llm-providers if needed.



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


## Documentation

### Documentation
- **Update ask-docs** after releasing v0.1.0 — the docs site at github.com/ask-rb/ask-docs must reflect this gems API, usage, and position in the ecosystem.
- The ask-docs repo has a Jekyll site with sections for each gem under core/, providers/, tools/, agent/.
- Add or update the relevant page(s) and submit a PR to ask-docs.
- This is not optional — ask-docs is the public face of the ecosystem.

## Improving Parent Gems During Development

### Improving Parent Gems During Development

If during development you discover something in a parent gem (a dependency of this gem)
that needs to be fixed or improved:

1. Make the change in the parent gem's repository at `/Users/kaka/Code/ask-rb/GEMNAME/`
2. Ensure existing tests in the parent gem still pass: `cd ../PARENT && bundle exec rake test`
3. Ensure tests in THIS gem still pass: `bundle exec rake test`
4. Ensure the parent gem still builds: `gem build *.gemspec`
5. Commit the parent gem change, bump its patch version, and push:
   `cd ../PARENT && git commit -m "fix: ..." && git push`
6. Update this gem's Gemfile to reference the updated parent gem
7. Continue with this gem's implementation using the fixed parent

Do NOT break parent functionality. Do NOT change parent APIs without testing
both gems. Parent gems have their own consumers — treat them with care.


## What Done Means for v0.1.0

The gem reaches v0.1.0 when:
- All implementation steps above are complete and tested
- The gem is released on RubyGems
- A real consumer can install it with gem install or Bundler
- A consumer script can require it and use its full public API
- The README provides enough information for someone unfamiliar to get started in 5 minutes
- The CHANGELOG documents what v0.1.0 delivers


## v0.1.0 Completion Checklist

A gem is NOT done until every item in this checklist passes. No shortcuts. If you cannot check every box, the gem is NOT finished.

### Code & Tests
- [ ] Every public method has unit tests (happy path + edge cases + error cases)
- [ ] Tests cover: normal operation, missing inputs, invalid inputs, network errors, auth failures
- [ ] Integration tests with real recorded API calls using VCR cassettes (for any gem that calls external APIs)
- [ ] All tests pass: `bundle exec rake test`
- [ ] Test coverage >= 90% (measure with simplecov)
- [ ] Thread-safety verified for any shared state (registries, config, client construction)
- [ ] No warnings on load
- [ ] No dependency conflicts

### Documentation
- [ ] README is complete: installation, quick start, configuration, examples, development
- [ ] Every public method documented (yardoc or inline comments)
- [ ] CHANGELOG.md exists with v0.1.0 entry

### Release
- [ ] Gem builds without errors: `gem build *.gemspec`
- [ ] Gem is released on RubyGems.org: `gem push *.gem`
- [ ] A fresh install works: `gem install GEMNAME` in a clean directory
- [ ] A consumer script can require and use the full public API

### Production Hardening
- [ ] Error messages are helpful and actionable (tell the user what went wrong AND what to do)
- [ ] Network timeouts handled (Timeout::Error, Errno::ECONNREFUSED, etc.)
- [ ] Retry logic for transient failures (rate limits, 429, 503)
- [ ] Sensible defaults for all configuration options
- [ ] Input validation rejects invalid parameters with clear messages
- [ ] Logging does not leak sensitive data (tokens, keys)

### CI/CD
- [ ] GitHub Actions workflow runs tests on push and PR (`.github/workflows/ci.yml`)
- [ ] CI passes on Ruby 3.2, 3.3, 3.4

### Post-Release
- [ ] ask-docs repository updated with this gem documentation
- [ ] Version tag exists: `git tag v0.1.0 && git push --tags`

### Service-Specific
- [ ] Full agent loop tested end-to-end (message -> tool call -> result -> follow-up)
- [ ] Streaming events tested (all event types fire correctly)
- [ ] Tool execution tested (parallel + sequential modes)
- [ ] Compactor tested (token estimation, compaction, overflow recovery)
- [ ] Hooks tested (before/after tool lifecycle)
- [ ] Persistence tested (in-memory + ActiveRecord)
- [ ] Extension system tested (register, hook lifecycle)
- [ ] Safety extensions tested (PermissionGate, RateLimiter, AuditLog)
- [ ] Error recovery tested (max turns, loop detection, context length exceeded, network errors)

## Development Workflow

### Git conventions
- The default branch is **master**. All work should be based on master unless a specific branch is requested.

- Follow the git-workflow skill for branch naming, commit messages, and PR structure.
- Use conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`.
- One logical change per commit. No "fixup" or "wip" commits on master.
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
