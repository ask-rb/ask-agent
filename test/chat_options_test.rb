# frozen_string_literal: true

require_relative "test_helper"

# Runtime model/provider/api_key overrides: the BYOK and user-credential
# injection seam — a caller can build a session against a specific provider
# and key without touching global configuration or Ask::Auth resolution.
class ChatOptionsTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)

  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "deepseek-v4-flash", provider: "opencode_go"))
  end

  def captured_provider_config(model:, **opts)
    captured = nil
    fake_class = Class.new do
      define_method(:initialize) { |config| captured = config }
    end
    Ask::Provider.stub(:resolve, ->(_slug) { fake_class }) do
      Ask::Agent::Chat.new(model: model, **opts).send(:provider)
    end
    captured
  end

  def test_explicit_api_key_reaches_provider_config
    config = captured_provider_config(model: "gpt-4o", provider: :openai, api_key: "sk-user-key")

    assert_equal "sk-user-key", config.api_key
    assert_equal "sk-user-key", config.openai_api_key
  end

  def test_explicit_api_key_wins_over_auth_resolution
    Ask::Auth.stub(:resolve, ->(*) { "auth-resolved-key" }) do
      config = captured_provider_config(model: "gpt-4o", provider: :openai, api_key: "sk-user-key")

      assert_equal "sk-user-key", config.api_key
    end
  end

  def test_auth_resolution_still_happens_without_an_explicit_key
    Ask::Auth.stub(:resolve, ->(*) { "auth-resolved-key" }) do
      config = captured_provider_config(model: "gpt-4o", provider: :openai)

      assert_equal "auth-resolved-key", config.api_key
    end
  end

  def test_explicit_api_base_reaches_provider_config
    config = captured_provider_config(model: "gpt-4o", provider: :openai, api_base: "https://custom.example/v1")

    assert_equal "https://custom.example/v1", config.openai_api_base
  end

  def test_session_build_accepts_runtime_model_provider_and_key
    Ask::Agent.stubs(:default_agent_paths).returns([File.join(FIXTURES, "agents")])
    Ask::Agent.rediscover!

    session = Ask::Agent.new("health_check", model: "deepseek-v4-flash", provider: :opencode_go, api_key: "sk-user-key")

    assert_equal "deepseek-v4-flash", session.chat.model_id
    config = session.chat.send(:provider_config, :opencode_go)
    assert_equal "sk-user-key", config.api_key
  ensure
    Ask::Agent.unstub(:default_agent_paths)
    Ask::Agent.instance_variable_set(:@discovered, false)
    Ask::Agent.instance_variable_set(:@registry, {})
    $LOADED_FEATURES.delete_if { |f| f.start_with?(FIXTURES) }
  end
end

  def test_explicit_account_id_reaches_provider_config
    config = captured_provider_config(model: "gpt-4o", provider: :openai, account_id: "acct_123")

    assert_equal "acct_123", config.account_id
  end
