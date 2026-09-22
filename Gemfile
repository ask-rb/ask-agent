source "https://rubygems.org"

gemspec

gem "ostruct"
gem "ask-core"

# Prefer local sibling checkouts when they exist (development against
# unreleased gems); otherwise resolve from rubygems.org so a standalone
# clone (e.g. CI) can bundle.
%w[ask-runtime ask-session ask-state-providers].each do |name|
  sibling = File.expand_path("../#{name}", __dir__)
  gem name, path: sibling if File.directory?(sibling)
end

gem "ask-llm-providers"
gem "ask-tools"
gem "ask-tools-shell"
gem "ask-skills"
gem "ask-schema"
gem "ask-instrumentation"

# Uncomment for local development against sibling gems:
# gem "ask-core", path: "../ask-core"
# gem "ask-llm-providers", path: "../ask-llm-providers"
# gem "ask-tools", path: "../ask-tools"
# gem "ask-tools-shell", path: "../ask-tools-shell"
# gem "ask-skills", path: "../ask-skills"
# gem "ask-schema", path: "../ask-schema"
# gem "ask-instrumentation", path: "../ask-instrumentation"

group :test do
  gem "minitest", "~> 5.25"
  gem "mocha", "~> 3.1"
  gem "rake", "~> 13.0"
  gem "sqlite3", "~> 2.9"
  gem "vcr", "~> 6.0"
  gem "webmock", "~> 3.26"
end

gem "rufus-scheduler", "~> 3.9"
