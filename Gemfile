source "https://rubygems.org"
gemspec

gem "ostruct"

group :test do
  gem "minitest", "~> 5.25"
  gem "mocha", "~> 3.1"
  gem "rake", "~> 13.0"
end

# Local development — use sibling gems on disk instead of RubyGems versions
ask_gems = %w[ask-core ask-llm-providers ask-tools ask-tools-shell ask-skills ask-schema ask-auth ask-instrumentation]
ask_gems.each do |name|
  path = File.expand_path("../#{name}", __dir__)
  gem name, path: path if Dir.exist?(path)
end
