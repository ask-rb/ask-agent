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
| `session.run(message)` | Run the loop for one message |
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
