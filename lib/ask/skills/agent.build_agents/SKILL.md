---
name: agent.build_agents
description: Build AI agents with ask-rb — define agents, register tools, configure sessions, and wire up the agent loop. Use when creating new agents, adding tools to existing agents, debugging agent behavior, or setting up agent definitions.
tags: agents, tools, sessions, ask-rb, development
---

# Building Agents with ask-rb

Step-by-step methodology for creating AI agents using the ask-rb ecosystem.

## Agent Definition (Convention-Based)

Every agent lives in a directory under `agents/` or `app/agents/`. The directory name is the agent name.

### Directory Structure

```
agents/
├── health_check/
│   ├── agent.rb           → Definition subclass (required)
│   ├── instructions.md    → System prompt (auto-loaded)
│   ├── tools/             → Per-agent tools (optional)
│   │   └── disk_check.rb
│   └── skills/            → Per-agent skills (optional)
│       └── nginx_debug/SKILL.md
├── shared/
│   ├── tools/             → Shared across all agents
│   │   └── notify.rb
│   └── skills/            → Shared skills
└── daily_report/
    ├── agent.rb
    └── instructions.md
```

### Definition DSL

```ruby
# agents/health_check/agent.rb
module HealthCheck
  class Agent < Ask::Agent::Definition
    model "gpt-4o"                    # required: which LLM to use
    provider :anthropic               # optional: override provider
    tools :bash, :read, :grep         # tool symbols or classes
    max_turns 30                      # optional: conversation limit
    parallel_tools true               # optional: parallel execution (default: true)
    skills_disclosure true            # optional: load_skill tool (default: true)
    schedule "every 5 minutes"        # optional: cron/interval
    option :temperature, 0.7          # optional: arbitrary Session option
  end
end
```

### Tool Symbol Resolution

Symbols (`:bash`, `:read`) are resolved in order:
1. Per-agent tools: `agents/<name>/tools/<name>.rb`
2. Shared tools: `agents/shared/tools/<name>.rb`
3. Global registry: `Ask::Tools[name]` (built-in tools from ask-tools)

## Session Creation (Unified API)

`Session.build_from_definition` is the single source of truth. Three entry points converge on it:

### From a Definition (Recommended)

```ruby
# Via Agent.new — convenience shorthand
agent = Ask::Agent.new("health_check")
agent.run("Check server health")

# Explicit — when you have the class and directory
session = Ask::Agent::Session.build_from_definition(
  HealthCheck::Agent, "agents/health_check"
)
```

### Direct (No Definition)

```ruby
session = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: [Ask::Tools::Bash, Ask::Tools::Read],
  system_prompt: "You are a helpful assistant."
)
session.run("Hello")
```

### One-Shot Chat

```ruby
Ask.chat("Check health")
Ask.chat("Check health", model: "claude-sonnet-4")
Ask.chat("Check health", name: "health_check")  # from definition
```

### Overriding Definition Config

Any explicit option overrides the definition's value:

```ruby
agent = Ask::Agent.new("health_check", model: "claude-sonnet-4")
agent = Ask::Agent.new("health_check", system_prompt: "Custom prompt")
```

## Writing Tools

### Tool Class

```ruby
# agents/health_check/tools/disk_check.rb
class DiskCheck < Ask::Tool
  description "Check disk usage on a path"
  param :path, type: :string, desc: "Path to check", required: true
  param :threshold, type: :integer, desc: "Warning threshold in %", default: 80

  def execute(path:, threshold: 80)
    usage = `df -h #{path} | tail -1 | awk '{print $5}'`.strip.to_i
    if usage > threshold
      Ask::Result.error(data: "Disk usage #{usage}% exceeds threshold #{threshold}%")
    else
      Ask::Result.ok(data: "Disk usage: #{usage}%")
    end
  end
end
```

### Tool Registration

```ruby
# In agent.rb — symbols resolve via convention
tools :bash, :read, :disk_check

# Or pass classes directly (no file convention needed)
tools Ask::Tools::Bash, DiskCheck
```

### Async Tools (Background Execution)

```ruby
class LongTask < Ask::Tool
  description "Run a long-running task in the background"

  def execute(task:)
    # Return pending — the loop continues while this runs
    Ask::Result.pending(
      tool_call_id: current_tool_call_id,
      message: "Task started in background"
    )
  end
end
```

Complete with `session.complete_pending_tool(tool_call_id:, result:)` from a background thread.

## Session Options

| Option | Default | Purpose |
|--------|---------|---------|
| `model:` | (required) | LLM model identifier |
| `tools:` | `[]` | Tool classes or instances |
| `system_prompt:` | `nil` | System instructions |
| `max_turns:` | `25` | Conversation turn limit |
| `max_tool_retries:` | `3` | Retries per failed tool call |
| `parallel_tools:` | `true` | Execute tools concurrently |
| `skills_disclosure:` | `true` | Include load_skill tool |
| `state:` | `nil` | Persistence adapter |
| `checkpoints:` | `false` | Enable fork/rollback |
| `todos:` | `false` | Enable task list tool |
| `plan_mode:` | `false` | Read-only research phase |
| `memory:` | `nil` | Durable memory adapter |
| `memory_learning:` | `false` | Auto-extract facts |
| `evaluator:` | `nil` | Independent evaluation |
| `reflector:` | `nil` | Self-reflection |
| `approval:` | `nil` | Human-in-the-loop |
| `compactor:` | `nil` | Context window management |
| `hooks:` | `{}` | Before/after tool callbacks |
| `telemetry:` | `true` | Error tracking |

## Event System

```ruby
session.on_event do |event|
  case event
  when Ask::Agent::Events::TextDelta
    print event.content
  when Ask::Agent::Events::ToolExecutionStart
    puts "Running #{event.name}..."
  when Ask::Agent::Events::SessionEnd
    puts "Done: #{event.tool_calls_made} tools, $#{event.cost}"
  end
end
```

## Common Patterns

### Multi-Agent Coordination

```ruby
search = Ask::Agent::SubAgent.new("web_search")
review = Ask::Agent::SubAgent.new("code_review")

coordinator = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: [search, review, Ask::Tools::Bash]
)
coordinator.run("Find the latest Rails release and check our Gemfile")
```

### Persistent Sessions

```ruby
store = Ask::State::Providers::SQLite.new
session = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: tools,
  state: store,
  checkpoints: true
)

session.run("Investigate the error")
restored = Ask::Agent::Session.load(session.id, adapter: store)
restored.run("What else should I check?")
```

### Scheduled Agents

```ruby
# In agent.rb:
class HealthCheck < Ask::Agent::Definition
  model "gpt-4o"
  tools :bash, :read
  schedule "every 5 minutes"
end

# Or globally:
Ask::Agent.configure do |c|
  c.scheduler.every "5 minutes", name: "health-check" do
    Ask::Agent.new("health_check").run("Check server health")
  end
end
Ask::Agent::Scheduler.start
```

## CLI

```bash
askr list                    # List all discovered agents
askr run health_check        # Run an agent
askr run health_check "..."  # Run with a prompt
askr new deploy_bot          # Scaffold a new agent
askr skills list             # List all discovered skills
askr skills install          # Install ask-agent skill to ~/.agents/skills/
askr skills uninstall        # Remove installed skill
```

## Troubleshooting

- **Agent not found**: Check `agents/<name>/agent.rb` exists and the class subclasses `Ask::Agent::Definition`
- **Tool not resolving**: Verify the tool file is in `agents/<name>/tools/` or registered in `Ask::Tools`
- **No system prompt**: Ensure `instructions.md` exists next to `agent.rb`
- **Skills not loading**: Check `skills_disclosure: true` (default) and the skill file follows `SKILL.md` convention
