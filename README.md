# ask-agent

Agent runtime for the ask-rb ecosystem. Runs the core agent loop: think, call
tools, execute, feed results back, and repeat until the task is done. Built on
ask-core, ask-state-providers, ask-llm-providers, ask-tools, ask-skills, and
ask-instrumentation, and it powers the `askr` CLI.

## Installation

```ruby
gem "ask-agent"
```

## Quick Start

```ruby
require "ask-agent"

session = Ask::Agent::Session.new(model: "gpt-4o", max_turns: 25)
response = session.run("What files are in the current directory?")
puts response
```

Stream execution in real time with events:

```ruby
session.on_event do |event|
  case event
  when Ask::Agent::Events::TextDelta
    print event.content
  when Ask::Agent::Events::ToolExecutionStart
    puts "\nRunning #{event.name}..."
  end
end
```

To also record provider-neutral ask-runtime tool lifecycle events, pass an
event sink to `Session#run`. For example, when using ask-session:

```ruby
require "ask-session"

host = Ask::Session::Host.new
host.create(id: session.id)
runtime_sink = host.sink(session.id)
session.run("What files are here?", runtime_event_sink: runtime_sink)
```

The sink receives tool start and terminal events, including failures,
cancellations, and timeouts. Leave `runtime_event_sink` unset if you do not
need this additional lifecycle stream. Integrations that already persist
protocol-facing tool events should avoid attaching a second sink to the same
host for those executions.

## Declarative Agents

Agents follow a file convention. Each agent lives in a directory under
`agents/` (or `app/agents/` in Rails); the directory name is the agent name,
the file `agent.rb` defines the agent as a `<Name>::Agent <
Ask::Agent::Definition` subclass, and a sibling `instructions.md` is
auto-loaded as the system prompt.

```
agents/
└── health_check/          # agent name: "health_check"
    ├── agent.rb           # module HealthCheck; class Agent < Ask::Agent::Definition
    ├── instructions.md    # auto-loaded system prompt
    └── tools/             # per-agent tools (referenced with `tools :name`)
```

```ruby
# agents/health_check/agent.rb
module HealthCheck
  class Agent < Ask::Agent::Definition
    model "gpt-4o"
    tools :bash, :read, :grep
  end
end
```

Run it by name:

```ruby
agent = Ask::Agent.new("health_check")
response = agent.run("Check server health")
```

Shared tools for all agents go in `agents/shared/tools/`. Per-agent skills go
in `agents/<name>/skills/`, shared skills in `agents/shared/skills/`.

## Essential API

| Entry point | Purpose |
|---|---|
| `Ask::Agent::Session.new(model:, tools: [], max_turns: 25, ...)` | Full agent loop: message, tool calls, results, follow-up |
| `session.run(message, runtime_event_sink: nil)` | Run the loop for one message; optionally emit ask-runtime tool lifecycle events to a sink |
| `session.on_event { \|e\| }` | Stream `Ask::Agent::Events` (text deltas, tool execution, evaluation) |
| `Ask::Agent.new("name")` | Build a session from a declarative agent definition |
| `Ask.chat(message)` | One-shot chat without instantiating a Session |
| `Ask::Agent.configure { \|c\| ... }` | Global defaults: model, provider, turns, compactor, middleware |
| `askr` | CLI: `askr run <agent> [prompt]`, `askr list`, `askr schedule`, `askr new`, `askr skills` |

### Configuration

```ruby
Ask::Agent.configure do |c|
  c.default_model = "claude-sonnet-4"
  c.default_provider = :anthropic
  c.default_max_turns = 50
  c.compactor_enabled = true
  c.compactor_threshold = 0.8
  c.parallel_tool_execution = true
  c.max_tool_retries = 3
end
```

`default_provider` pins which provider serves the default model when the model
name doesn't uniquely identify one (for example, the same model id registered
under multiple OpenAI-compatible providers). A `provider:` passed to
`Session.new` or declared in an agent `Definition` always wins over the global
default.

### Tool approval

`Session.new(approval: ...)` turns on human-in-the-loop approval: matching
tool calls queue on `session.approval_queue` instead of executing until
`approve(id)` / `reject(id)` is called. `approval: true` enables defaults; a
Hash accepts:

| Option | Purpose |
|---|---|
| `require_approval:` | tool names / regexps / `:all` that must be approved |
| `auto_approve:` | user-enabled rules keyed by tool name (pairs with `auto_approvable` tools) |
| `rules:` | an `Ask::Permissions::PermissionRules` block (`allow` / `ask` / `deny`) |
| `mode:` | baseline policy — `:full_access`, `:ask_before_changes`, or `:read_only` |
| `queue:` | a custom `Ask::Permissions::ApprovalQueue` |
| `session_grants:` / `project_grants:` | grant collaborators (session- and project-scoped approvals) |

```ruby
session = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: [SendEmail],
  approval: { mode: :read_only }
)
```

`mode:` is forwarded to `Ask::Permissions::ApprovalPolicy`: `:full_access`
runs every tool without asking, `:ask_before_changes` queues tool calls for
approval, and `:read_only` refuses them outright. Unknown keys in the
`approval:` hash raise `ArgumentError` instead of being silently ignored.

## Durable sessions (ask-session)

`Ask::Agent::SessionAdapter` bridges a session to an event-sourced
`Ask::Session::Host`. Every run records the user input, the mapped agent
events, and an `agent.snapshot`; `SessionAdapter.resume` restores the latest
snapshot — including after a process restart, as long as the host store is
durable (for example `Ask::Session::ProviderStore` over
`ask-state-providers`' SQLite adapter).

```ruby
require "ask-agent"
require "ask/session"

host = Ask::Session::Host.new(store: Ask::Session::Store.new)

session = Ask::Agent::Session.new(model: "gpt-4o", id: "chat-1")
adapter = Ask::Agent::SessionAdapter.create(agent: session, host: host)
adapter.run("Hello")

# Later (even in a new process, with the same durable store):
resumed = Ask::Agent::Session.new(model: "gpt-4o", id: "chat-1")
adapter = Ask::Agent::SessionAdapter.resume(agent: resumed, host: host, session_id: "chat-1")
adapter.run("Continue where we left off")
```

`SessionAdapter::Error` is raised when the session record or its latest
snapshot cannot be found. This requires the `ask-session` gem (a runtime
dependency of ask-agent).

## Full documentation

The full ask-rb documentation lives at https://ask-rb.github.io/ask-docs.
https://ask-rb.github.io/ask-docs/core/agent covers ask-agent in depth,
including the evaluator, middleware, extensions, cost tracking, and
persistence. API reference: https://ask-rb.github.io/ask-docs/reference/api.

## Development

bundle install
bundle exec rake test

## License

MIT
