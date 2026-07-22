# ask-agent

Agent runtime for the ask-rb ecosystem. The core agent loop: think → call tools → execute → feed back → repeat.

Ported from `RubyLLM::Conductor` into the `Ask::Agent` namespace.

## Installation

```ruby
gem "ask-agent"
```

## Quick Start

```ruby
require "ask-agent"

session = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: [Ask::Tools::Shell::Bash, Ask::Tools::Shell::Read]
)

response = session.run("What files are in the current directory?")
puts response
```

## Components

| Component | File | Purpose |
|---|---|---|
| `Ask::Agent::Session` | session.rb | Full agent loop — message → tool calls → results → follow-up |
| `Ask::Agent::Loop` | loop.rb | Turn management, loop detection, max-turn guard |
| `Ask::Agent::ToolExecutor` | tool_executor.rb | Parallel/sequential tool execution with retry and abort |
| `Ask::Agent::Compactor` | compactor.rb | Context window management with proactive/overflow compaction |
| `Ask::Agent::Hooks` | hooks.rb | Before/after tool lifecycle callbacks |
| `Ask::Agent::Events` | events.rb | Data.define event types for streaming and monitoring |
| `Ask::Agent::Telemetry` | telemetry.rb | File-backed telemetry for error tracking |
| `Ask::Agent::Reflector` | reflector.rb | Assistant response self-evaluation |
| `Ask::Agent::MetaAgent` | meta_agent.rb | LLM-powered self-improvement from telemetry |
| `Ask::Agent::Configuration` | configuration.rb | Global config: model, turns, concurrency |

## Events

Stream session execution in real-time:

```ruby
session.on_event do |event|
  case event
  when Ask::Agent::Events::TextDelta
    print event.content
  when Ask::Agent::Events::ToolExecutionStart
    puts "\nRunning #{event.name}..."
  when Ask::Agent::Events::ToolExecutionEnd
    puts "  → #{event.duration_ms}ms #{event.is_error ? 'error' : 'ok'}"
  end
end
```

## Extensions

Opt-in safety modules:

- **Permissions** — Access control for tools. Supports named access modes (`:full_access`, `:read_only`, `:ask_before_changes`) or custom blocked-tool lists.
- **RateLimiter** — Prevent runaway tool calls (configurable per-minute and per-turn limits)
- **AuditLog** — Immutable, append-only log of every tool call

```ruby
extensions = [
  Ask::Agent::Extensions::Permissions.new(mode: :read_only),
  Ask::Agent::Extensions::RateLimiter.new(max_calls_per_minute: 30),
  Ask::Agent::Extensions::AuditLog.new(path: "agent.log")
]

session = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: [...],
  hooks: {
    before_tool: extensions.map(&:method(:before_tool_call)),
    after_tool: extensions.select { |e| e.respond_to?(:after_tool_call) }.map(&:method(:after_tool_call))
  }
)
```

## Configuration

```ruby
Ask::Agent.configure do |c|
  c.default_model = "claude-sonnet-4"
  c.default_max_turns = 50
  c.compactor_enabled = true
  c.compactor_threshold = 0.8
  c.parallel_tool_execution = true
  c.max_tool_retries = 3
end
```

## Persistence

```ruby
store = Ask::Agent::Persistence::InMemory.new
session = Ask::Agent::Session.new(model: "gpt-4o", persistence: store)
session.run("Hello")
session.save  # persisted to store
```

## Development

```bash
bundle exec rake test
```

## License

MIT
