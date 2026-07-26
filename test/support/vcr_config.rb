# frozen_string_literal: true

require "vcr"
require "fileutils"

# VCR Configuration for ask-agent integration tests.
#
# Cassettes are stored in test/fixtures/vcr_cassettes/ and are shared with
# the ask-llm-providers test suite. On first run with API keys set, VCR
# records all HTTP interactions. Subsequent runs replay the cassettes.
#
# In CI (when CI env var is set), VCR will not record — only replay.
# This means PRs must include cassettes for any new integration tests.
VCR.configure do |config|
  cassette_library = File.expand_path("../../fixtures/vcr_cassettes", __dir__)
  config.cassette_library_dir = cassette_library
  config.hook_into :webmock
  config.default_cassette_options = {
    record: ENV["CI"] ? :none : :once
  }

  # Create cassette directory if it doesn't exist
  FileUtils.mkdir_p(cassette_library)

  # Allow HTTP connections when no cassette is loaded
  config.allow_http_connections_when_no_cassette = true

  # Filter out API keys from recorded cassettes
  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") { ENV.fetch("ANTHROPIC_API_KEY", nil) }
  config.filter_sensitive_data("<AZURE_AI_AUTH_KEY>") { ENV.fetch("AZURE_AI_AUTH_KEY", nil) }
  config.filter_sensitive_data("<DEEPSEEK_API_KEY>") { ENV.fetch("DEEPSEEK_API_KEY", nil) }
  config.filter_sensitive_data("<GEMINI_API_KEY>") { ENV.fetch("GEMINI_API_KEY", nil) }
  config.filter_sensitive_data("<MISTRAL_API_KEY>") { ENV.fetch("MISTRAL_API_KEY", nil) }
  config.filter_sensitive_data("<OPENAI_API_KEY>") { ENV.fetch("OPENAI_API_KEY", nil) }
  config.filter_sensitive_data("<OPENCODE_GO_API_KEY>") { ENV.fetch("OPENCODE_GO_API_KEY", nil) }
  config.filter_sensitive_data("<OPENROUTER_API_KEY>") { ENV.fetch("OPENROUTER_API_KEY", nil) }
  config.filter_sensitive_data("<XAI_API_KEY>") { ENV.fetch("XAI_API_KEY", nil) }

  # Filter Bearer tokens in Authorization headers
  config.filter_sensitive_data("Bearer <AUTH_TOKEN>") do |interaction|
    auth = interaction.request.headers["Authorization"]&.first
    auth if auth&.start_with?("Bearer ")
  end

  # Filter common response headers that change between runs
  config.filter_sensitive_data("<REQUEST_ID>") { |i| i.response.headers["Request-Id"]&.first }
  config.filter_sensitive_data("<X_REQUEST_ID>") { |i| i.response.headers["X-Request-Id"]&.first }
  config.filter_sensitive_data("<CF_RAY>") { |i| i.response.headers["Cf-Ray"]&.first }
end
