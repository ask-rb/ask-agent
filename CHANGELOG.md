## [Unreleased]

### Changed

- **Plan-mode tool gate delegates to `Ask::Permissions::PlanModePolicy`.**
  `Session` now configures one shared policy (`allowed_tools:` from the
  session's read-only tool list, `exit_tool: "exit_plan_mode"`) instead of
  hand-rolling the allow/block check in `plan_mode_gate`, which now only
  checks that plan mode is still active and delegates. The gate hook is
  still installed only when plan mode is enabled, and approval still turns
  the gate off. Exposes the configured policy as `Session#plan_mode_policy`.

## [0.40.30] — 2026-09-23

### Added

- **`Session#run(runtime_event_sink:)` forwards ask-runtime tool lifecycle events** through the agent loop and recursive turns to `ToolExecutor#execute_batch`.

### Changed

- **Permission machinery extracted to the `ask-permissions` gem.**
  `Ask::Agent::ApprovalQueue`, `Ask::Agent::Policies::ApprovalPolicy`,
  `Ask::Agent::Policies::PermissionRules`, and
  `Ask::Agent::Policies::Permissions` are removed from ask-agent; the same
  classes now ship as `Ask::Permissions::ApprovalQueue`,
  `Ask::Permissions::ApprovalPolicy`, `Ask::Permissions::PermissionRules`,
  and `Ask::Permissions::Permissions` behind `require "ask/permissions"`.
  Session keeps its agent-specific wiring — the `approval:` option still
  builds the queue, wires on_approve/on_reject/on_submit callbacks, and
  prepends the policy hook; the plan queue is unchanged apart from the
  constant. Requires the new runtime dependency `ask-permissions >= 0.1.0`.

### Fixed

- **`SessionAdapter.resume` surfaces every ask-session miss as
  `SessionAdapter::Error`.** The `Host#events` lookup ran outside the
  `Ask::Session::NotFoundError` rescue, so a missing record reported by the
  events fetch leaked the ask-session error across the adapter boundary
  instead of the documented `SessionAdapter::Error`.


## [0.40.21] — 2026-09-22

### Added

- **`Ask::Agent::SessionAdapter` — bridges an agent session to
  `Ask::Session::Host`.** Records user input and per-run snapshots as
  event-sourced ask-session events, maps agent events (turn, streaming,
  tool, todo, plan, error) onto session event types with `trace_id` /
  `causation_id` propagation, and resumes from the latest snapshot
  (`SessionAdapter.resume`). Resume survives process restarts when the host
  store is durable (e.g. `Ask::Session::ProviderStore` over
  `ask-state-providers`). Requires the new runtime dependency
  `ask-session >= 0.1.0` (the single session store; no second store added).
  Resume validates the snapshot before restoring, so a malformed snapshot
  raises `SessionAdapter::Error` instead of leaving the agent half-restored.

### Fixed

- **`Session#turn_count` is now maintained during runs.** The counter was
  only ever reset at run start (or restored from a checkpoint), never
  incremented — so `SessionEnd`, audit-log entries, persisted
  `metadata.turn_count`, and `SessionAdapter` snapshots all recorded `0` for
  live runs. Turns are now counted on `TurnStart`, matching the loop's own
  count (`reset: true` scopes it to the run; `reset: false` accumulates).


## [0.40.20] — 2026-09-21

### Changed

- **Agent tool execution unified with ask-runtime.** `ToolExecutor` runs
  tool calls through the runtime's execution contract, exposing the current
  runtime call and execution context (`Ask.current_runtime_call` /
  `Ask.current_runtime_context`) while a tool executes, and conforming to
  the runtime executor contract.
- Requires `ask-runtime >= 0.1.0`.


## [0.40.19] — 2026-09-20

### Added

- **Bundled `agent.build_agents` skill** — teaches building agents with
  ask-rb (definitions, sessions, tools, configuration, common patterns).
  Auto-discovered via `Gem.find_files` when ask-skills is present.
- **`askr skills install` / `askr skills uninstall`** with
  `--global|--local|--dir`, plus auto-sync of managed skill copies on
  every CLI invocation.


## [0.40.18] — 2026-09-19

### Changed

- **`Agent.new` and `Session.new` unified.** The shared implementation
  lives in `Session.build_from_definition`; `Agent.new` delegates to it,
  `Session.new` supports definition lookup, and `Ask.chat` accepts `name:`
  for definition lookup. The duplicate `build_session_from_definition` and
  `resolve_definition_tools` helpers were removed from the `Agent` module.


## [0.40.17] — 2026-09-18

### Added

- **`decision_provider` — a session can take a decision provider, and its
  tool calls get judged.** Set it globally
  (`Ask::Agent.configure { |c| c.decision_provider = :typesafe }`) or per
  session. `Ask::Decisions::AgentAdapter` then wires a gate in front of every
  tool call and an output judge behind it; ask-agent itself never requires
  ask-decisions, and with the setting unset nothing changes at all.

### Changed

- Requires `ask-core >= 0.12.0` for the decision vocabulary.


## [0.40.10] — 2026-09-05

### Fixed

- **`Chat#ask` no longer appends an empty user message for blank input.** The guard `if message || attachments` passed for empty strings (truthy in Ruby), so tool-result follow-ups (`Session#run_follow_up` → `ask("")`) sent `{"role":"user","content":""}`. Strict OpenAI-compatible gateways (e.g. Command Code / LiteLLM) reject it with 400 "user message must have content". Blank messages are now skipped (whitespace-only included); attachments-only asks are unchanged.

## [0.40.0] — 2026-08-10

### Fixed

- **Approval race: completing a queued tool call now always lands.**
  The approval policy queues a tool call inside the executor (before_tool
  hook), but the loop only registered the pending call *after* the executor
  returned. An approval landing in that window found nothing to complete —
  the call was then registered as a ghost pending entry and the turn never
  settled. Two changes close it:
  - `ApprovalQueue` gains an `on_submit` callback that fires **before** the
    auto-approval drain; `Session#build_approval` (and the plan queue) wire
    it to `register_pending_tool`, so the pending call exists the moment the
    action is queued.
  - `Session#register_pending_tool` skips re-registration for calls that
    were already resolved (`action_id` check) or recently completed
    (bounded `@recently_completed` set), so a late loop registration cannot
    resurrect a completed call.

### Added

- `ApprovalQueue#on_submit` accessor and `on_submit:` initializer argument.

## [0.38.0] — 2026-08-07

### Added

- **Artifacts — tool deliverables with a web-friendly home.**
  `Session.new(artifacts: true)` collects tool-produced files into an
  `Ask::Agent::ArtifactStore` on the same state adapter as sessions and
  checkpoints:
  - Tools attach `metadata: { artifact: { filename:, mime_type:, content: | uri: } }`
    to their result. **Inline content** (small text: reports, CSVs,
    patches) is stored in the state store; **external URIs** (large or
    binary files) are stored as references with metadata only.
  - `Session#artifacts` lists them (newest first, no content payload);
    `Session#fetch_artifact(id)` retrieves the full record. `Session#delete`
    cleans up.
  - **Uploader hook** — `Session.new(artifacts: true, artifact_uploader:
    ->(content:, filename:, mime_type:) { uri })` lifts inline content to a
    URI before storage, so apps that prefer object storage never grow the
    database: tools return content, the session uploads, the store keeps
    the reference.
  - Malformed artifacts never fail the tool — the message notes
    `[artifact not stored: ...]` instead.

## [0.37.0] — 2026-08-07

### Added

- **Steer — concurrency-safe message injection.**
  `Session#steer(message, expected_turn_id:)` lets any thread (web, CLI,
  another agent) inject a message safely:
  - **`:stale`** — `expected_turn_id` doesn't match the current turn id
    (the caller was looking at an older state); the message is rejected.
  - **`:queued`** — a turn is running; the message is held and dispatched
    as the next user message at the next turn boundary (the loop now
    resolves each recursive turn's message from a steer source). No more
    abort-and-retry.
  - **`:steered`** — the session is idle; the message enters the
    conversation and the next run processes it. Queued leftovers drain at
    the next run start.
  - `Session#turn_id` tracks the running turn (bumped on `TurnStart`);
    `Session#queued_steers` reports pending messages.

### Fixed

- **No more duplicate tail checkpoints.** The loop persists after every
  turn and `run()` persists again on the way out, so every run previously
  appended a redundant checkpoint (seqs 1,2,3 for two turns). `persist!`
  now skips the checkpoint when the message count and turn count are
  unchanged — `checkpoint_history` is exact.

## [0.36.0] — 2026-08-07

### Added

- **Large-output offloading — tool results never bloat the transcript.**
  `Session.new(offload_large_outputs: true)` (or an Integer threshold,
  default 4000 chars) stores tool messages above the threshold in a
  state-backed store; the transcript keeps a short preview plus a reference
  the model retrieves with the injected `output_read` tool:
  - `Ask::Agent::ToolOutputStore` — pure KV on the same
    `Ask::State::Adapter` as sessions/checkpoints/memory
    (`output:<session_id>:<call_id>` + JSON index), works with every
    backend; in-process Memory fallback when no `state:` is given. Stored
    outputs are capped (`max_size:`, default 50,000 chars).
  - `output_read` is exempt from offloading — its contract is to bring the
    full output into context on demand.
  - `Session#delete` cleans up the session's stored outputs.
  - The loop now passes `session_id` to the tool executor (previously nil),
    which offloading relies on.

## [0.35.0] — 2026-08-07

### Added

- **Memory learning — automatic extraction (v2 of durable memory).**
  `Session.new(memory: memory, memory_learning: true)` extracts durable
  facts from the transcript when the session ends — the model no longer has
  to remember to call `memory_write`:
  - `Ask::Agent::MemoryExtractor` reads the memory-relevant messages (user
    + assistant, capped, oldest dropped), sends them to the model with a
    configurable structured-output prompt, and writes the returned facts
    into the store — deduped (exact + near-duplicate via search), stamped
    with provenance (`extracted: true`, source session id), and capped
    (`max_candidates:`, default 10).
  - Extraction is best-effort: unparseable responses and failed calls
    yield an empty result and never break the session.
  - `Memory.new(max_entries:)` prunes the oldest entries once a namespace
    exceeds the cap — bounded memory, not a growing dump.
  - Requires `memory:`; `memory_learning:` without it raises.

## [0.34.1] — 2026-08-07

### Added

- **`account_id` session option.** `Ask::Agent::Chat.new(..., account_id:)` merges the value into the provider config (e.g. `ChatGPT-Account-Id` for the OpenAI Codex provider).

## [0.34.0] — 2026-08-07

### Added

- **Runtime model/provider/key overrides.** `Ask::Agent.new(name, model:, provider:, api_key:, api_base:)` and `Ask::Agent::Chat.new(..., api_key:, api_base:)` — caller-supplied options win over the definition's config, and an explicit `api_key`/`api_base` is merged into the provider config ahead of Ask::Auth resolution. This is the BYOK / per-user credential injection seam (a session can be built against a specific provider and key without touching global configuration).

## [0.33.0] — 2026-08-06

### Added

- **Durable memory — facts that outlive sessions.** `Ask::Agent::Memory`
  stores namespaced entries on the same `Ask::State::Adapter` as sessions
  and checkpoints (no new dependencies, no ask-rag mandate):
  - Storage: one key per entry (`memory:<namespace>:<id>`) plus a JSON
    index key for enumeration — pure KV, works with every backend
    (SQLite/Redis/Postgres/MySQL/custom adapters) and with the in-process
    Memory store.
  - `Memory#write` (dedupes identical content), `#search` (keyword
    substring match, ranked by matched terms, punctuation-stripped
    queries), `#list`, `#delete`, `#count`. Namespaces isolate tenants and
    agent roles.
  - **Session integration**: `Session.new(memory: memory)` injects
    `memory_write` (stamps the session id as provenance) and
    `memory_search` tools, and **injects relevant memories as a system
    message at run start** — session B starts knowing what session A
    learned. Opt-in; sessions without `memory:` are unaffected.

## [0.32.0] — 2026-08-06

### Added

- **TodoWrite — the model maintains a live task list.** `Session.new(todos:
  true)` injects a `todo_write` tool backed by a session-scoped
  `Ask::Agent::TodoList`:
  - Actions `add` / `update` / `list` / `clear` with `pending`,
    `in_progress`, `completed`, `blocked` statuses; every result returns
    the full list so one call both mutates and shows state.
  - `Events::TodoUpdated` fires with the full list on every change — the
    contract for live progress rendering (UI kit / app server).
  - The list is part of the checkpoint snapshot: `rollback!` and `fork`
    restore it, and `Session.load` re-enables todos automatically.
- **Plan mode — research first, execute after human approval.** `Session.new(
  plan_mode: true)` (or `plan_mode: { read_only_tools: [...] }`) starts the
  session in a research phase where non-read-only tools are blocked
  (`:block` with a plan-mode reason; the gate runs before user hooks and
  the approval policy). The model researches, then calls the injected
  `exit_plan_mode` tool with its plan:
  - The plan is submitted to a dedicated `Session#plan_queue` and the tool
    returns a pending result — the agent hands back the interim reply,
    exactly like the tool-approval flow.
  - **Approve** → plan mode turns off, `Events::PlanApproved` fires, and a
    follow-up turn executes the plan. **Reject** → the session stays in
    plan mode, `Events::PlanRejected` fires, and the rejection feedback
    reaches the conversation.
  - Default read-only allowlist: `read`, `glob`, `grep`, `web_search`.

## [0.31.0] — 2026-08-06

### Added

- **Permission rules — persisted allow/ask/deny patterns for tool calls.**
  `Ask::Agent::Policies::PermissionRules` classifies every call before it
  executes or prompts, so "approve once, remember the pattern" replaces
  per-call prompting:
  - DSL in declaration order (first match wins): `allow`, `ask`, `deny`
    with a tool pattern (String, Symbol, Regexp, or `:all`) and an optional
    argument pattern (Regexp, substring, or `nil` for any).
  - Wire in via `Session.new(approval: { rules: rules })`. Rules take
    precedence over a tool's own `approval_required` / `auto_approvable`
    declarations: `:deny` blocks, `:allow` proceeds without the queue,
    `:ask` queues regardless of auto-approvable.
  - **Dangerous-rule guard**: an unrestricted `:allow` on a code-executing
    tool (`bash`, `code`, `repl`, or `:all`) is downgraded to `:ask` unless
    the ruleset is created with `auto_allow_dangerous: true` — "approve
    once" can't become "approve anything". `dangerous_rules` reports which
    rules were affected.

## [0.30.1] — 2026-08-06

### Fixed

- **Framework-injected tools are no longer persisted in session metadata.**
  The built-in `load_skill` tool was saved alongside user tools and could
  not be auto-instantiated on load (`LoadSkillTool` requires a registry), so
  the previous 0.30.0 fix skipped it with a broad rescue. Persisted metadata
  now contains only user-supplied tools (`persisted_tools`); `load_skill` is
  re-added by `resolve_tools` per session with a proper registry.
- **`Session.load` no longer swallows tool-restore failures silently.** The
  safety net now rescues only `NameError` (renamed/removed classes) and
  `ArgumentError` (constructors with required args), and warns with the
  tool name instead of failing the whole load — genuine tool bugs surface
  instead of disappearing.

## [0.30.0] — 2026-08-06

### Added

- **Session checkpoints: fork, rollback, resume.** Versioned, durable
  checkpoints on any state adapter. Enable with
  `Session.new(state: store, checkpoints: true)` — every turn is snapshotted
  under a sequential key, and the session gains time travel:
  - **`Session#rollback!(seq: / turn:)`** — rewind messages and turn count
    to an earlier checkpoint. Later checkpoints are kept, so the session
    can roll forward again. The legacy blob stays consistent.
  - **`Session#fork(at_seq: / at_turn:)`** — a new session (new id, same
    model/tools) whose history is everything up to that point, backed by
    its own checkpoint chain; continue the branch with `run`.
  - **`Session#checkpoint_history` / `Session#load_checkpoint(seq:)`** —
    inspect the timeline. `Session.load` re-enables checkpointing
    automatically when the stored session has checkpoints.
  - `Ask::Agent::CheckpointStore` — the store itself, usable standalone.
    It needs only the minimal KV contract (`get`/`set`/`delete`), so it
    works with every state provider (SQLite, Redis, Postgres, MySQL) and
    custom adapters — no list primitives required, no provider mandated.
  - `Events::SessionRolledBack` / `Events::SessionForked` fire on rollback
    and fork. `Session#delete` cleans up checkpoint keys too.

### Fixed

- **`Session.load` could not restore sessions saved with tools.** The
  built-in `LoadSkillTool` (auto-added to every session) cannot be
  instantiated without a registry, so any saved session with tools failed
  to load with `ArgumentError: missing keyword: :registry`. Load now
  instantiates saved tool classes defensively — un-instantiable classes are
  skipped and re-added by `resolve_tools` with a proper registry.

## [0.29.1] — 2026-08-06

### Fixed

- **Streamed token accounting now counts real tokens.** Stream usage arrives
  as OpenAI-style `prompt_tokens`/`completion_tokens` (deepseek, openai,
  most OpenAI-compatible providers), but `accumulated_tokens` read only
  `input_tokens`/`output_tokens` — every streamed call reported 0 input and
  ~1 output token (the content-chunk fallback), so token billing, cost
  calculation, and usage metrics under-counted by orders of magnitude. Both
  key shapes are read now, and the content-chunk fallback applies only when
  the stream carries no usage at all (no double counting).

## [0.29.0] — 2026-08-06

### Added

- **Tool-call repair** — malformed tool calls get one internal LLM round-trip
  to fix them before execution. When a model emits a call with unparseable
  arguments or an unknown tool name, the loop asks the model to re-emit it
  corrected and executes the corrected version instead of burning a turn on
  the error. Enable with `Session.new(tool_call_repair: true)` (built-in
  repair prompt) or pass a callable for full control:
  `Session.new(tool_call_repair: ->(chat, calls, tools) { ... })`.
  - Corrections are remapped to the original call ids, so tool results stay
    consistent with the conversation history; the internal repair exchange
    is stripped from history.
  - Calls the model cannot correct are dropped (the model saw them in the
    repair prompt); repair is best-effort — a failing round-trip drops the
    malformed calls instead of failing the turn.
  - `Events::ToolCallRepaired` fires with name, id, original and corrected
    arguments.

## [0.28.0] — 2026-08-06

### Changed (breaking)

- **`Ask::Agent::Extensions` is now `Ask::Agent::Policies`.** The
  tool-lifecycle policy classes — `ApprovalPolicy`, `Permissions`,
  `RateLimiter`, `AuditLog` — moved from `lib/ask/agent/extensions/` to
  `lib/ask/agent/policies/` and are namespaced under `Ask::Agent::Policies`.
  The folder is now named after its seam (like `middleware`,
  `stream_transforms`, `persistence`) instead of "extra stuff".
  `Ask::Agent.load_extensions` → `Ask::Agent.load_policies`.
  Update references: `Ask::Agent::Extensions::X` → `Ask::Agent::Policies::X`.

  **What this means for the taxonomy:** policies are opt-in, replaceable
  implementations of the tool-lifecycle hook seam — the agent loop runs
  without them, and users can swap in their own implementations. Core
  mechanisms are unchanged and stay on `Session`: the approval queue, the
  `:pending` result status, and the `approval: true` option are core;
  `Policies::ApprovalPolicy` is the reference classification policy wired on
  top of them.

### Added

- **`Ask::Agent.load_policies`** — replaces `load_extensions` (same
  behavior: eagerly requires every policy in the policies directory).

## [0.27.1] — 2026-08-06

### Fixed

- **`chat.ask` / `chat.stream.ask` events now measure real LLM latency.** The
  event was emitted after the call without a block, so `event.duration` was
  ~0ms and duration metrics (e.g. `ask_llm_duration_seconds`,
  `llm.duration_ms` spans) were meaningless. The provider call now runs
  inside the instrument block; tokens/cost/tool_calls are enriched through a
  shared nested `usage` payload hash (known only after the call returns) and
  subscribers read it from there. Instrumentation failures can no longer
  fail an `ask` — a wrapper error before the call falls through and runs the
  call without telemetry, and a subscriber error after success returns the
  response.

## [0.27.0] — 2026-08-06

### Added

- **Human-in-the-loop tool approval — `Ask::Agent::ApprovalQueue`.** Tools
  declared `approval_required` (ask-tools) are queued instead of executed:
  the agent receives a pending result and continues, and the tool runs only
  after a human approves it. Built on the async-tools seam
  (`Ask::Result.pending` → `register_pending_tool` → `complete_pending_tool`).

  ```ruby
  session = Ask::Agent::Session.new(
    model: "gpt-4o",
    tools: [SendEmail],          # SendEmail.approval_required true
    approval: { auto_approve: {} }
  )
  session.run("Email bob about the launch")

  # Later, when the user decides:
  session.approval_queue.pending_actions   # inspect what's waiting
  session.approval_queue.approve_all       # or approve(id) / reject(id)
  ```

  - `approval: true` enables with defaults; a Hash accepts
    `require_approval:` (tool names / regexps / `:all`) and `auto_approve:`
    (user-enabled rules keyed by tool name). A custom `ApprovalQueue`
    instance is accepted too.
  - **Auto-approval is a dual signal** — a tool marked `auto_approvable`
    AND a user rule enabling it. Nothing is silently applied past a manual
    (non-auto-approvable) gate; eligible actions drain in id order with a
    single-flight guard (no double-apply).
  - **Approving executes the real tool** and feeds the result into the
    conversation; **rejecting** injects a "rejected by the user" message and
    the agent adapts. Failed applies leave the action pending for retry.
  - `Session#approval_queue` returns the queue (nil when approval is off).

- **`Ask::Agent::Extensions::ApprovalPolicy`** — the classification hook.
  Queues calls for tools whose class declares `approval_required`, or whose
  name matches rule-based lists, or (with `require_approval: :all`) every
  call. Usable standalone as a `before_tool` hook.

### Changed

- `ToolExecutor` before-tool hooks now support a `:pending` action alongside
  `:block` and `:short_circuit`, returning a pending tool result.

## [0.26.1] - 2026-08-05

### Added

- **`Session#pending_tools?`** — true while any async tool is still running;
  the voice seam uses it to tell the worker a completion is coming.

## [0.26.0] - 2026-08-05

### Added

- **Async tools (pending results).** A tool can return `Ask::Result.pending`
  (ask-core 0.10.0) to hand the turn back with its interim message — the
  agent voices it immediately and keeps talking — while the real work runs
  in the background. The tool reads `Ask::Agent.current_session` and
  `Ask::Agent.current_tool_call_id` (thread-locals set during the run and
  the tool call) and completes later via
  `Session#complete_pending_tool(tool_call_id:, result:)`, which adds the
  tool message to the conversation and runs a follow-up turn so the agent
  voices the answer. Completions that land mid-turn queue until the turn
  ends. `ToolPending`/`ToolCompleted` events are emitted; the loop stops
  after a pending call (no recursion, no loop detection, no premature
  chat message).

## [0.25.6] - 2026-08-05

### Added

- **The agent loop honors `Session#abort` (barge-in).** Aborting a running
  session now stops the loop as soon as the in-flight LLM call ends: no
  tool execution, no follow-up turns, and recursion stops after a tool
  turn. Voice callers who interrupt the agent get their new turn processed
  immediately instead of waiting for the stale answer to finish. Emitters
  without `abort_requested?` (plain stubs) are treated as never aborted.

## [0.25.5] - 2026-08-05

### Changed

- **`load_skill` tool moved to ask-skills.** Sessions now inject
  `Ask::Skills::LoadSkillTool` (ask-skills owns discovery, listing, and
  loading). No API change for session users — `skills_disclosure false`
  still opts out of the auto-injected tool.

## [0.25.4] - 2026-08-05

### Added

- **`skills_disclosure` opt-out for progressive skill disclosure.** Sessions
  auto-inject the `load_skill` tool by default; agents with a fixed tool
  surface (e.g. voice receptionists) can declare `skills_disclosure false`
  in their definition (or pass `skills_disclosure: false` to
  `Session.new`) to keep the tool payload minimal and deterministic.

## [0.25.3] - 2026-08-04

### Fixed

- **Tools now respect the session's `parallel_tools` setting.** The agent
  loop dispatched tool calls straight to `execute_parallel`, so tools always
  ran in worker threads — even with `parallel_tools: false`. Sequential
  sessions now run tools in the caller thread, which is what frameworks
  like Rails rely on for per-request context (`CurrentAttributes` are
  thread-local). The loop calls `ToolExecutor#execute`, which honors the
  executor's `parallel` flag.
- **Parallel tool threads inherit the caller's thread-local state.** When
  tools do run in threads (parallel mode), `execute_parallel` copies the
  caller's `Thread.current` locals into each worker thread first, so
  per-request context (Rails `CurrentAttributes`, log tags, etc.) reaches
  the tools instead of being nil.
- `ToolExecutor#execute` accepts a `result_callback:` kwarg (invoked per
  completed tool in both sequential and parallel modes); sequential
  execution reports results through it too, matching parallel behavior.

## [0.25.2] - 2026-08-03

### Fixed

- **Streaming no longer depends on ActiveSupport's `String#truncate`.** The
  SSE event serialization (streaming.rb) and the max-consecutive-tool-turns
  summary (loop.rb) called `String#truncate`, which only exists when
  ActiveSupport's core extensions are loaded — so a bare `require
  "ask-agent"` raised `NoMethodError` as soon as a tool emitted a partial
  result. Both call sites now use a plain-Ruby truncation helper.

## [0.25.1] - 2026-08-02

### Fixed

- **Session passes resolved tool instances to Chat.** Tool classes passed
  as `tools: [MyTool]` were resolved for the session but handed to the
  underlying Chat unresolved, so `ToolDef.from_tool` used `Class#name`
  and raised `Ask::InvalidToolDefinition` on the first run. Sessions now
  resolve tools before building the Chat; classes and instances both work.

## [0.25.0] — 2026-08-02

### Added

- **Model-aware compaction reserve.** `Ask::Agent::Compactor` now derives
  its context headroom from the model's declared `max_output_tokens`
  (capped at 20,000) instead of a fixed 80% threshold. When the model
  metadata is unavailable, a static 20,000-token reserve applies. A safety
  floor clamps the reserve for tiny-window models so compaction can fire
  usefully instead of triggering on every turn.

  ```ruby
  # Default: compact when tokens exceed context_window - reserve
  compactor = Ask::Agent::Compactor.new

  # Legacy behavior: compact at 80% of the window
  compactor = Ask::Agent::Compactor.new(threshold: 0.8)

  # Explicit headroom
  compactor = Ask::Agent::Compactor.new(reserve_tokens: 5_000)
  ```

- **Token-aware recent tail.** `keep_recent_tokens:` preserves the last N
  tokens of conversation verbatim (default 8,000) and summarizes only what's
  older — recent-context fidelity depends on the active work, not message
  counts. When not configured, the legacy fixed message-count tail
  (`keep_count:`, default 8) is used for backward compatibility.

- **Global compaction options** on `Ask::Agent.configure`:
  `compactor_reserve_tokens` and `compactor_keep_recent_tokens` apply to all
  sessions. `compactor_threshold` now defaults to `nil` (reserve mode).

- **`Compactor#compact_threshold_tokens`** — public accessor for the token
  count at which compaction triggers (window × threshold, or
  window − reserve).

### Fixed

- **`microcompact!` no longer crashes on long tool results.** `Ask::Message`
  is immutable — `content=` never existed. The method now rebuilds the
  message in place via `map!`, preserving `tool_call_id` and metadata.

### Changed

- `Compactor#extract_summary` is now public.

## [0.24.2] — 2026-07-30

### Fixed

- **Definitions discovered through an intermediate base class no longer
  crash.** `Definition.inherited` appended to `@subclasses` on `self`, so
  subclassing `Ask::Agent::Definition` through an application base class
  (e.g. `class Agent < ApplicationAgent` in a Rails app) made the ivar nil
  and raised `NoMethodError` on load. Tracking now reads the registry from
  `Definition` itself, and `Definition.subclasses` reports the same list
  regardless of receiver.

- **Changelog for 0.24.1.** The subclass-chain fix shipped as 0.24.1
  without a changelog entry; it is documented here and republished as
  0.24.2 so the gem content includes it.

## [0.24.0] — 2026-07-30

### Changed

- **Agent class convention is now `<Name>::Agent`, not `<Name>Agent`.**
  `agents/health_check/agent.rb` defines `module HealthCheck; class Agent <
  Ask::Agent::Definition` — matching the ecosystem's `Xxx::Workflow` /
  `Xxx::Create` naming. Directory-based discovery is unchanged.

### Fixed

- **Discovery re-points definitions when the class constant is re-opened.**
  Requiring an `agent.rb` from a second location (same agent name, e.g. test
  fixtures) re-opens the existing `<Name>::Agent` constant instead of
  redefining it, so `inherited` never fires and the definition kept its old
  directory. Discovery now falls back to matching by conventional class name
  and re-points `_config[:dir]` at the current directory.

## [0.23.0] — 2026-07-30

### Added

- **`Ask::Agent::Configuration#default_provider` — global default provider**.
  Pins which provider serves the default model when the model id is
  registered under multiple providers (e.g. the same model on several
  OpenAI-compatible endpoints). `Chat#build_provider` falls back to the
  global default before the model's own catalog entry. A per-chat
  `provider:` override or a Definition-level `provider` always wins.

## [0.22.0] — 2026-07-26

### Added

- **`Ask::Agent::Extensions::AuditLog` — event-driven audit logging with pluggable adapters**.
  Subscribes to all session events and writes them to a configurable adapter.
  Ships with two built-in adapters:

  - **`FileAdapter`** — appends JSON lines to a file (development/quick-start)
  - **`ActiveRecordWriter`** — writes to an `ask_audit_logs` table, auto-creates it
    on first write using `CREATE TABLE IF NOT EXISTS`. Works with or without Rails
    migrations.

  ```ruby
  # Global config (all sessions)
  Ask::Agent.configure { |c| c.audit_log = { adapter: :active_record } }

  # Per-session
  session = Ask::Agent::Session.new(model: "gpt-4o", audit_log: { adapter: :file })
  ```

  Events logged: `session_start`, `session_end`, `turn_end`, `tool_execution_start`,
  `tool_execution_end`, `error`, `max_turns_exceeded`, `loop_detected`,
  `compaction_end`, `evaluation_blocked`.

  Sensitive arguments (password, token, api_key, sql, etc.) are redacted automatically.

- **12 tests** for AuditLog — adapter contract, event subscription, config integration,
  sensitive arg redaction, legacy hook interface.

### Changed

- `Session#initialize` now accepts `audit_log:` parameter and falls back to
  `Ask::Agent.configuration.audit_log`.
- `Ask::Agent::Configuration#audit_log` — new accessor for global audit log config.

## [0.21.0] — 2026-07-26

- Version bump only.

## [0.20.0] — 2026-07-26

### Added

- **`Events::ThinkingDelta`** — new event emitted when a chunk has thinking/reasoning
  content. The loop already received chunks with `.thinking` data from providers like
  DeepSeek and Claude, but it wasn't exposed as a dedicated event. Now it is.
- **`Ask::Agent::Streaming`** — framework-agnostic SSE streaming module. Returns a
  Rack-compatible Enumerator that yields SSE-formatted strings as the agent runs.
  Works with any Rack server without requiring Rails or ActionController::Live.

  Two modes:
  - **Enumerable mode** (no block) — for Rack/Roda/Sinatra:
    ```ruby
    stream = Ask::Agent::Streaming.run(session, prompt)
    [200, { "Content-Type" => "text/event-stream" }, stream]
    ```
  - **Block mode** — for Rails `ActionController::Live::SSE`:
    ```ruby
    Ask::Agent::Streaming.run(session, prompt) do |type, data|
      sse.write(data, event: type)
    end
    ```

- **19 tests** for Streaming + ThinkingDelta — Enumerator mode, block mode, custom
  event maps, error handling, SSE line format, event structure.

## [0.19.0] — 2026-07-26

### Added

- **`Ask::Agent::SubAgent.new("definition_name")` — create sub-agents from
  filesystem definitions**. Passing a string looks up an agent definition
  by name (same convention as `Ask::Agent.new("name")`), reading model,
  tools, instructions, and other settings from the definition files.

  ```ruby
  # agents/web_search/agent.rb defines model, tools, instructions
  search = Ask::Agent::SubAgent.new("web_search")

  coordinator = Ask::Agent::Session.new(
    model: "gpt-4o",
    tools: [search, Ask::Tools::Shell::Bash]
  )
  ```

- **VCR-based integration tests** for SubAgent. Real API calls are recorded
  and replayed via VCR cassettes. Run with `OPENAI_API_KEY` set to record,
  or without to replay existing cassettes.

### Changed

- `Ask::Agent::SubAgent.new(name:, ...)` now supports `provider:` parameter
  for provider-specific sub-agents.

## [0.18.0] — 2026-07-26

### Added

- **`Ask::Agent::SubAgent` — delegate tasks to a specialized sub-agent tool**.
  A self-contained tool class that satisfies the tool duck type (`name`,
  `description`, `params_schema`, `call`). When the coordinator LLM calls it,
  a fresh sub-agent session runs independently with its own model, tools,
  and instructions.

  ```ruby
  search = Ask::Agent::SubAgent.new(
    name: "web_search",
    description: "Search the web for current information",
    model: "gpt-4o-mini",
    tools: [MyApp::Tools::WebSearch],
    system_prompt: "You are a research assistant."
  )

  coordinator = Ask::Agent::Session.new(
    model: "gpt-4o",
    tools: [search, Ask::Tools::Shell::Bash]
  )

  coordinator.run("What's the latest Rails release and how stable is it?")
  ```

### Removed

- **`Ask::Agent.sub_agent_tool`** factory method — replaced by the
  `Ask::Agent::SubAgent` class directly. The class IS the tool, no
  factory or wrapper needed.

## [0.17.0] — 2026-07-26

### Added

- Bump ask-tools dependency for `Ask::Tools::SubAgent` support

### Added

- **Independent Evaluator — `Ask::Agent::Evaluator`** — Generator/evaluator separation.
  A separate model (configured independently from the session's model) judges the
  agent's output against a structured rubric before delivery. This prevents the
  anti-pattern of a model grading its own work.

  ```ruby
  # Evaluate with a different model — the recommended approach
  session = Ask::Agent::Session.new(
    model: "gpt-4o",
    evaluator: { model: "claude-sonnet-4", goal: "Write an email validator" }
  )
  session.run("Write email validation")
  ```

  Three verdicts:
  - **`:accept`** — output meets the goal, passes through to reflection
  - **`:revise`** — evaluator provides actionable feedback; session runs another
    turn with the feedback injected into system context
  - **`:block`** — output is fundamentally wrong; session returns blocked message
    and emits `Events::EvaluationBlocked`

  Rubric dimensions (each scored 0-2):
  - correctness (3× weight), completeness (2×), verification (2×), scope (1×), clarity (1×)

  Custom rubrics supported:
  ```ruby
  evaluator = Ask::Agent::Evaluator.new(
    model: "claude-sonnet-4",
    rubric: [
      Ask::Agent::Evaluator::Dimension.new(name: "performance", description: "Is it fast?", weight: 2)
    ]
  )
  ```

- **`evaluator:` option on `Session`** — accepts `true`, `false`/`nil`, or a Hash:
  - `evaluator: true` — uses `config.default_evaluator_model` (falls back to the
    session's model, though using a different model is strongly recommended)
  - `evaluator: { model: "claude-sonnet-4", goal: "Custom goal" }` — explicit config
  - `evaluator: false` (default) — no evaluation, backward compatible

- **`default_evaluator_model` config option** — set a global default:
  ```ruby
  Ask::Agent.configure do |c|
    c.default_evaluator_model = "claude-sonnet-4"
  end
  ```

- **New event types** for streaming evaluation:
  - `Events::EvaluationStart` — emitted when evaluation begins (includes dimension list)
  - `Events::EvaluationDelta` — streamed evaluation text from the evaluator model
  - `Events::EvaluationEnd` — emitted with decision, feedback, scores, and evidence
  - `Events::EvaluationBlocked` — emitted when evaluator returns `:block`

- **17 unit tests** for Evaluator — construction, rubric, all three verdicts, event
  emission, custom rubrics, JSON parsing, and malformed response fallback.

- **7 integration tests** for Session with evaluator — config (true/hash),
  revise triggers improvement, revise skips reflector, block returns blocked
  message, block emits event, evaluator-not-configured skips evaluation.

## [0.14.0] — 2026-07-23

### Added

- **`state:` keyword on Session** — Accepts any `Ask::State::Adapter` directly. Sessions persist conversation state, tool results, and metadata. Replaces `persistence:` keyword (still supported for backward compatibility).
- **Per-turn persistence** — Session now persists after every LLM turn, not just at the end of `run()`. Mid-session crashes no longer lose progress.
- **`Session.load` restores `@messages`** — Previously `session.messages` returned `nil` after loading. Now it's populated from the restored chat messages.
- **`Ask::State::Adapter#clear`** — Abstract method added to the adapter contract. Memory adapter implements it.

### Changed

- **Session behind the scenes now uses `@state.set`/`@state.get`/`@state.delete`** instead of the old `@persistence.save`/`@persistence.load`/`@persistence.delete`. Custom adapters must respond to `set`/`get`/`delete`.

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
