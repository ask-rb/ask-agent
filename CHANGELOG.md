## [0.13.0] — 2026-07-23

### Added

- **ModelFallback middleware** — Switches to a fallback model+provider when the primary LLM call fails with a rate limit, server error, or service unavailable. Supports static and dynamic (lambda-based) fallback lists. Credentials resolve automatically via `Ask::Auth`.
  - Static fallbacks: ordered list of `{ model:, provider: }` hashes
  - Dynamic fallbacks: lambda receiving `(error, request)` returning the list
  - Custom eligible errors: configure which errors trigger fallback
  - Each fallback builds its own provider instance with resolved credentials

### Changed

- `Pipeline::KNOWN_MIDDLEWARES` now includes `:model_fallback`.

## [0.12.0] — 2026-07-22

### Added

- **System Context algebra** — typed, independently-observable context sources
  that compose into the system prompt. Each source has a unique key, a `load`
  function, a `baseline` render for initialization, and an `update` render for
  mid-conversation changes.

- **Built-in context sources:**
  - `Instructions` — agent's core system prompt / instructions.md
  - `SkillsList` — "## Available Skills" listing from the skills registry
  - `AlwaysActiveSkills` — full instructions for skills with `always: true`
  - `Date` — today's date in ISO 8601 format

- **`SystemContext#changes`** — detects which sources have changed since the
  last snapshot and returns update texts. Enables mid-conversation updates
  (e.g., date rollover, skill registry changes) without rebuilding the entire
  prompt.

- **`Ask::Agent::ContextSource` base class** — DSL for defining typed context
  sources with `key`, `load`, `baseline`, and optional `update`.

- **`Session` uses SystemContext** — the system prompt is now assembled from
  typed sources instead of string concatenation, with 17 tests covering
  rendering, change detection, and source composition.

## [0.11.0] — 2026-07-22

### Added

- **`Definition#parallel_tools` DSL** — set parallel tool execution per agent:
  ```ruby
  class MyAgent < Ask::Agent::Definition
    model "gpt-4o"
    parallel_tools false
  end
  ```
  Defaults to `true`.

- **`Definition#option` DSL** — pass arbitrary Session options:
  ```ruby
  class MyAgent < Ask::Agent::Definition
    model "gpt-4o"
    option :temperature, 0.7
    option :reflector, true
  end
  ```

- **17 new tests** for Definition DSL — model, provider, max_turns, parallel_tools, tools, schedule, option, instructions_path, instructions_content, subclass tracking.

### Fixed

- **`build_session_from_definition` passes `parallel_tools` and custom options** to `Session.new`. Previously only `model`, `provider`, and `max_turns` were forwarded.

## [0.10.0] — 2026-07-21

### Added

- **`askr skills` CLI commands** — new subcommands for discovering and inspecting skills:

  ```bash
  askr skills list              # All discovered skills with descriptions and tags
  askr skills show rails_debug  # Full details + instructions + sibling files
  askr skills search deploy     # Search by name, description, or tags
  ```

  Skills commands integrate with ask-skills 0.4.0, supporting enhanced frontmatter (tags, version, metadata) and sibling file discovery.

## [0.9.1] — 2026-07-21

### Changed

- **`prompt_caching` now defaults to `true`** globally. All sessions automatically send cache-control hints to supporting providers (Anthropic, OpenAI). Non-supporting providers ignore the parameter safely.

## [0.9.0] — 2026-07-21

### Added

- **Prompt caching support** — `prompt_caching` option enables provider-native prompt caching for significant cost savings on repeated conversation prefixes. Works with both Anthropic and OpenAI.

  ```ruby
  # Global config
  Ask::Agent.configure do |c|
    c.prompt_caching = true
  end

  # Or per-session
  session = Ask::Agent::Session.new(model: "claude-sonnet-4", prompt_caching: true)
  ```

  **Anthropic**: Caches the system prompt and the last user message content. The provider automatically returns cached reads instead of processing the full context on repeated calls. Response metadata includes `cache_creation_input_tokens` and `cache_read_input_tokens`.

  **OpenAI**: Caching is automatic for prompts exceeding 1024 tokens. Response metadata includes `cached_tokens` from `usage.prompt_tokens_details.cached_tokens`.

- **Prompt caching capability** — Both `Ask::Providers::Anthropic` and `Ask::Providers::OpenAI` now advertise `prompt_caching: true` in their capabilities.

## [0.8.1] — 2026-07-21

### Added

- **Per-agent skills via `agent_dir:`** — `Session` now accepts `agent_dir:` parameter. When set, `Ask::Skills.discover(agent_dir:)` discovers skills scoped to that agent directory, loading them alongside shared skills.

- **Agent definitions pass `agent_dir` automatically** — `Ask::Agent.new("name")` passes the agent's directory path to `Session`, enabling per-agent skill discovery without any configuration.

### Changed

- `Ask::Agent::Session#initialize` now accepts optional `agent_dir:` keyword.
- Skills discovery in Session uses `Ask::Skills.discover(agent_dir: @agent_dir)` instead of the plain `Ask::Skills.discover`, enabling the new per-agent and shared skills paths from ask-skills 0.3.0.

## [0.8.0] — 2026-07-21

### Added

- **Provider-executed tool support in the agent loop** — `ResponseMessage` now carries a `tool_results` field for pre-computed results from provider-executed tools (e.g. OpenAI web search, file search, code interpreter). The `Loop` detects these results, adds them directly to the conversation without local execution, then proceeds with any remaining user tool calls.

  ```ruby
  agent = Ask::Agent.new("health_check")
  agent.run("Search the web for server status")
  # web_search runs on OpenAI's side; results come back pre-computed
  ```

### Changed

- **`ResponseMessage`** added `tool_results` field (default `{}`). All existing call sites are compatible via keyword argument defaults.
- **`Loop#run_turn`** — separates provider-executed results from user tool calls. Provider results are added to the conversation immediately. User tool calls continue to be executed locally via `ToolExecutor`.
- **OpenAI provider** — `split_tools` separates `Ask::ProviderTool` objects from regular tools. `format_responses_tools` converts provider tools to the Responses API format. When provider tools are present, the Responses API endpoint is used instead of Chat Completions.

### Tested

- 13 new integration tests: loop handling with mixed tool types, provider-only tools, tool splitting, Responses API formatting.
- Full suite: 329 tests, 592 assertions — 0 failures.

## [0.7.0] — 2026-07-21

### Added

- **Agent definitions — `Ask::Agent::Definition`** — Declarative agent configuration via subclassing. Define agents in `agents/<name>/agent.rb` or `app/agents/<name>/agent.rb`. The directory name becomes the agent name. Instructions auto-load from a sibling `instructions.md`.

  ```ruby
  # agents/health_check/agent.rb
  class HealthCheckAgent < Ask::Agent::Definition
    model "gpt-4o"
    tools :bash, :read, :grep
    schedule "every 5 minutes"
  end
  ```

- **`Ask::Agent.new(name)`** — Create a configured `Session` from a named definition. Discovers agents from `agents/` and `app/agents/` automatically on first call.

  ```ruby
  agent = Ask::Agent.new("health_check")
  agent.run("Check server health")
  ```

- **`Ask::Agent.definitions`** — Returns all discovered definitions as a hash keyed by agent name. Each entry is `[Definition_subclass, directory_path]`.

- **`Ask::Agent.rediscover!`** — Force re-discovery when agent files change.

- **Shared tools** — `agents/shared/tools/*.rb` are auto-discovered and available to all agents in the same project.

- **`askr` CLI** — New command-line tool for running, listing, scheduling, and scaffolding agents.

  ```bash
  askr list                    # List all discovered agents
  askr run health_check        # Run an agent (interactive if no prompt)
  askr schedule                # Start the scheduler for all scheduled agents
  askr new deploy_bot          # Scaffold a new agent directory
  ```

### Changed

- **New dependency** — Ask::Agent::CLI module added to the lib path. `exe/askr` is registered as a gem executable.
- **Test fixture agents** added under `test/fixtures/agents/` and `test/fixtures/app/agents/` for discovery testing.

## [0.6.1] — 2026-07-21

### Changed

- **`Persistence::Base` now wraps `Ask::State::Adapter`** (from ask-core 0.3.0). Session persistence is backed by the unified state interface instead of a standalone abstract class. `Persistence::InMemory` delegates to `Ask::State::Memory`. The public API is unchanged — `save`, `load`, `delete`, and `list` work identically.
- **`Persistence::Base.new` accepts `state_adapter:` keyword** for custom backends. Defaults to `Ask::State::Memory` (same behavior as before).
- **`Persistence::Base#list`** now returns a deduplicated list ordered by most-recently-saved.

## [0.6.0] — 2026-07-21

### Added

- **Agent Scheduler** — `Ask::Agent::Scheduler` runs recurring agent tasks on cron schedules or human-readable intervals. Configure tasks alongside middleware and transforms, then start the background loop.

  ```ruby
  Ask::Agent.configure do |c|
    c.scheduler.every "5 minutes", name: "health-check" do
      Ask::Agent::Session.new(model: "gpt-4o").run("Check server health")
    end

    c.scheduler.cron "0 9 * * 1-5", name: "morning-report" do
      Ask::Agent::Session.new(model: "gpt-4o").run("Generate daily report")
    end
  end

  Ask::Agent::Scheduler.start   # background thread loop
  Ask::Agent::Scheduler.stop    # graceful shutdown
  ```

  Manage the scheduler at runtime:
  - `Ask::Agent::Scheduler.running?` — check if the loop is active
  - `Ask::Agent::Scheduler.jobs` — list all scheduled jobs (returns `Rufus::Scheduler::Job` objects with `.name`, `.next_time`, etc.)
  - `Ask::Agent::Scheduler.job_by_name("health-check")` — find a specific job
  - Tasks without blocks are valid — they register but execute nothing

  Powered by `rufus-scheduler` (added as a runtime dependency). The scheduler is optional — users who don't configure any tasks are unaffected.

### Changed

- **`Ask::Agent::Configuration`** now exposes `#scheduler` returning a `SchedulerConfig` DSL proxy. No breaking changes for existing users.
- **Gemspec** — added `rufus-scheduler ~> 3.9` as a runtime dependency.

## [0.5.0] — 2026-07-21

### Added

- **Middleware pipeline for LLM provider calls** — `Ask::Agent::Middleware::Pipeline` lets you wrap every `provider.chat(...)` call with cross-cutting behavior. Configured globally and automatically used by all `Chat` and `Session` instances.

  ```ruby
  Ask::Agent.configure do |c|
    c.middleware.use :retry_on_failure, max_retries: 5
    c.middleware.use :log_calls, logger: Rails.logger
    c.middleware.use :default_settings, temperature: 0.7
  end
  ```

  Three built-in middlewares:
  - **`RetryOnFailure`** — Exponential backoff retry on `RateLimitError`, `ServerError`, and `ServiceUnavailable`. Does not retry on fatal errors (`Unauthorized`, `ModelNotFound`, `ConfigurationError`). Respects `retry_after` from provider responses.
  - **`LogCalls`** — Logs every LLM call with model, tool count, message count, duration, and token usage. Custom logger support (defaults to `$stdout`).
  - **`DefaultSettings`** — Injects default generation parameters (`temperature`, `max_tokens`, `top_p`, etc.) into the provider call request.

  Custom middlewares extend `Ask::Agent::Middleware::Base` and override `#around_request`:

  ```ruby
  class MyMiddleware < Ask::Agent::Middleware::Base
    def around_request(provider, request)
      Rails.logger.info "Calling #{request[:model]}"
      yield
    end
  end

  Ask::Agent.configure { |c| c.middleware.use MyMiddleware }
  ```

- **Stream transform pipeline** — `Ask::Agent::StreamTransforms::Pipeline` processes each raw `Ask::Chunk` through a chain of transforms before yielding `ChatChunks` to the caller. Configured globally.

  ```ruby
  Ask::Agent.configure do |c|
    c.stream_transforms.use :thinking_separator
    c.stream_transforms.use :text_buffer, min_size: 100
  end
  ```

  Three built-in transforms:
  - **`ThinkingSeparator`** — Splits chunks that contain both `thinking` and visible `content` into two separate chunks, so you can handle thinking tokens independently.
  - **`TextBuffer`** — Coalesces rapid text deltas into larger contiguous chunks (minimum configurable size). Reduces UI updates and log entries. Automatically flushes before non-content chunks and when the stream finishes.
  - **`ExtractJson`** — Accumulates the streaming response and attempts to parse it as JSON. Provides `#extracted_json` and `#json?` accessors for post-stream inspection.

  Custom transforms extend `Ask::Agent::StreamTransforms::Base` and override `#call`:

  ```ruby
  class FilterTransform < Ask::Agent::StreamTransforms::Base
    def call(chunk, &block)
      block.call(chunk) unless chunk.content == "drop_me"
    end
  end

  Ask::Agent.configure { |c| c.stream_transforms.use FilterTransform }
  ```

### Changed

- **`Ask::Agent::Configuration`** now exposes `#middleware` and `#stream_transforms` pipelines. Both are pre-initialized as empty pipelines — no breaking changes for existing users.
- **`Ask::Agent::Chat`** reads middleware and stream transforms from global configuration on initialization. If configured, all provider calls go through the middleware chain and all stream chunks through the transform chain.
- **Test helper** now includes local `ask-core`, `ask-auth`, `ask-instrumentation`, and `ask-llm-providers` in the load path so tests run against development code rather than installed gems.

## [0.4.5] — 2026-07-18

### Fixed

- **`ToolExecutor#try_call` now respects `Ask::Result#ok?` for error detection** — Previously the method always set `is_error: false`, treating all Ask::Result returns as successful even when `ok?` was false. Tool failures returned via `Ask::Result.failure(...)` are now properly detected as errors, preventing the agent from silently ignoring failed tool executions and looping.

## [0.4.4] — 2026-07-18

### Added

- **`ToolExecutor` detects `halted: true` from tool results and stops execution** — When a tool returns `Ask::Result.ok(metadata: { halted: true })`, the executor now detects this flag, aborts sibling tools in parallel mode, and stops sequential execution. Previously the `halted` metadata was set but never checked by the executor, causing the agent loop to continue calling tools after a tool signaled completion.

## [0.4.3] — 2026-07-18

### Added

- **`Chat#provider_config` passes multiple credential names and path segments to `Ask::Auth.resolve`** — For compound provider slugs like `opencode_go`, the method now tries flat key names (`:opencode_go_api_key`, `:opencode_api_key`) and path segments (`[:opencode, :go, :api_key]`, `[:opencode, :api_key]`) as fallbacks. This lets `Ask::Auth.resolve` find credentials stored under various naming conventions.

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
