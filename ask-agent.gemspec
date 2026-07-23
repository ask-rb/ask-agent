require_relative "lib/ask/agent/version"

Gem::Specification.new do |spec|
  spec.name = "ask-agent"
  spec.version = Ask::Agent::VERSION
  spec.authors = ["Kaka Ruto"]
  spec.email = ["kaka@myrrlabs.com"]

  spec.summary = "Agent runtime for the ask-rb ecosystem"
  spec.description = "Agent loop, session management, tool execution, context compaction, hooks, and extensions."
  spec.homepage = "https://github.com/ask-rb/ask-agent"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "exe/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["askr"]

  spec.add_dependency "ask-core", ">= 0.1"
  spec.add_dependency "ask-state-providers", ">= 0.1"
  spec.add_dependency "ask-llm-providers", ">= 0.1"
  spec.add_dependency "ask-tools", ">= 0.1"
  spec.add_dependency "ask-skills", ">= 0.1"
  spec.add_dependency "ask-instrumentation", ">= 0.1"
  spec.add_dependency "rufus-scheduler", "~> 3.9"

  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "mocha", "~> 3.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
