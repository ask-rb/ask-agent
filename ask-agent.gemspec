require_relative "lib/ask/agent/version"

Gem::Specification.new do |spec|
  spec.name = "ask-agent"
  spec.version = Ask::Agent::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@anywaye.com"]

  spec.summary = "Agent runtime for the ask-rb ecosystem"
  spec.description = "Agent loop, session management, tool execution, context compaction, hooks, and extensions."
  spec.homepage = "https://github.com/ask-rb/ask-agent"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ask-tools", "~> 0.1"
  spec.add_dependency "ask-tools-shell", "~> 0.1"

  spec.add_development_dependency "ruby_llm", ">= 1.14"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
