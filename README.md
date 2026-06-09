# ask-agent

The core agent loop: think → call tools → execute → feed back → repeat. Renamed from
`ruby_llm-conductor`.

Provides `Ask::Agent::Session`, `Loop`, `ToolExecutor`, `Compactor`, `Hooks`, `Events`,
and persistence. Works with any `Ask::Tool` subclass.

## Installation

```ruby
gem "ask-agent"
```

## Usage

```ruby
session = Ask::Agent::Session.new(
  model: "gpt-4o",
  tools: Ask::Tools::Shell.all
)

session.run("List all Ruby files in the project") do |event|
  case event
  in Ask::Agent::Event::Chunk(content:) then write(content)
  in Ask::Agent::Event::ToolCalled(name:, arguments:) then log(name, arguments)
  end
end
```

## Migration from ruby_llm-conductor

See [MIGRATION.md](MIGRATION.md) for details on moving from `RubyLLM::Conductor`.

## Development

```bash
bin/setup
bundle exec rake test
```

## License

MIT
