# frozen_string_literal: true

require_relative "test_helper"

class MiddlewareModelFallbackTest < Minitest::Test
  def setup
    @request = { model: "gpt-4o", messages: [{ role: "user", content: "hi" }], temperature: 0.7, stream: false, tools: [], extra_params: {} }
    @provider = Object.new
  end

  # --- Basic passthrough ---

  def test_passthrough_on_success
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])

    call_count = 0
    result = mw.around_request(@provider, @request) {
      call_count += 1
      "success"
    }
    assert_equal "success", result
    assert_equal 1, call_count
  end

  # --- Fallback on eligible errors ---

  def test_fallbacks_on_rate_limit
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "fallback response")

    call_count = 0
    result = mw.around_request(@provider, @request) {
      call_count += 1
      raise Ask::RateLimitError, "rate limited"
    }
    assert_equal "fallback response", result
    assert_equal 1, call_count, "Primary should be called once before fallback"
  end

  def test_fallbacks_on_server_error
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "ok from fallback")

    result = mw.around_request(@provider, @request) {
      raise Ask::ServerError, "500"
    }
    assert_equal "ok from fallback", result
  end

  def test_fallbacks_on_service_unavailable
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "ok")

    result = mw.around_request(@provider, @request) {
      raise Ask::ServiceUnavailable, "503"
    }
    assert_equal "ok", result
  end

  # --- Non-eligible errors should not trigger fallback ---

  def test_does_not_fallback_on_unauthorized
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "should not reach")

    assert_raises(Ask::Unauthorized) {
      mw.around_request(@provider, @request) {
        raise Ask::Unauthorized, "bad key"
      }
    }
  end

  def test_does_not_fallback_on_invalid_credential
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "should not reach")

    assert_raises(Ask::InvalidCredential) {
      mw.around_request(@provider, @request) {
        raise Ask::InvalidCredential, "bad token"
      }
    }
  end

  def test_does_not_fallback_on_model_not_found
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "should not reach")

    assert_raises(Ask::ModelNotFound) {
      mw.around_request(@provider, @request) {
        raise Ask::ModelNotFound, "unknown"
      }
    }
  end

  def test_does_not_fallback_on_configuration_error
    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    stub_fallback_provider(mw, "should not reach")

    assert_raises(Ask::ConfigurationError) {
      mw.around_request(@provider, @request) {
        raise Ask::ConfigurationError, "bad config"
      }
    }
  end

  # --- Multiple fallbacks ---

  def test_tries_multiple_fallbacks_in_order
    provider1 = stub_provider_raising(Ask::RateLimitError.new("also limited"))
    provider2 = stub_provider_returning("second fallback worked")

    fallback_providers = [provider1, provider2]
    mw = build_mw(fallbacks: [
      { model: "claude-sonnet-4", provider: :anthropic },
      { model: "gemini-2.0-flash", provider: :google }
    ])
    mw.define_singleton_method(:build_fallback_provider) { |_| fallback_providers.shift }

    result = mw.around_request(@provider, @request) {
      raise Ask::RateLimitError, "limit"
    }
    assert_equal "second fallback worked", result
  end

  def test_raises_when_all_fallbacks_exhausted
    provider1 = stub_provider_raising(Ask::RateLimitError.new("also limited"))
    provider2 = stub_provider_raising(Ask::ServerError.new("500"))

    fallback_providers = [provider1, provider2]
    mw = build_mw(fallbacks: [
      { model: "claude-sonnet-4", provider: :anthropic },
      { model: "gemini-2.0-flash", provider: :google }
    ])
    mw.define_singleton_method(:build_fallback_provider) { |_| fallback_providers.shift }

    assert_raises(Ask::RateLimitError) {
      mw.around_request(@provider, @request) {
        raise Ask::RateLimitError, "limit"
      }
    }
  end

  # --- Updates request model ---

  def test_updates_request_model_for_fallback
    fallback = Object.new
    captured_model = nil
    fallback.define_singleton_method(:chat) { |*args, **kwargs|
      captured_model = kwargs[:model]
      "ok"
    }

    mw = build_mw(fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }])
    mw.define_singleton_method(:build_fallback_provider) { |_| fallback }

    mw.around_request(@provider, @request) { raise Ask::RateLimitError, "limit" }
    assert_equal "claude-sonnet-4", @request[:model]
    assert_equal "claude-sonnet-4", captured_model
  end

  # --- Dynamic fallback list (lambda form) ---

  def test_dynamic_fallback_list
    mw = build_mw(fallbacks: ->(error, request) {
      [{ model: "claude-sonnet-4", provider: :anthropic }]
    })
    stub_fallback_provider(mw, "dynamic ok")

    result = mw.around_request(@provider, @request) {
      raise Ask::RateLimitError, "limit"
    }
    assert_equal "dynamic ok", result
  end

  def test_dynamic_fallback_receives_error_and_request
    captured = {}
    mw = build_mw(fallbacks: ->(error, request) {
      captured[:error_class] = error.class
      captured[:model] = request[:model]
      [{ model: "claude-sonnet-4", provider: :anthropic }]
    })
    stub_fallback_provider(mw, "ok")

    mw.around_request(@provider, @request) { raise Ask::RateLimitError, "limit" }
    assert_equal Ask::RateLimitError, captured[:error_class]
    assert_equal "gpt-4o", captured[:model]
  end

  # --- Custom eligible errors ---

  def test_custom_eligible_errors
    mw = build_mw(
      fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }],
      eligible_errors: [ArgumentError]
    )
    stub_fallback_provider(mw, "custom fallback")

    result = mw.around_request(@provider, @request) {
      raise ArgumentError, "bad arg"
    }
    assert_equal "custom fallback", result
  end

  # --- Constructor validation ---

  def test_requires_at_least_one_fallback
    assert_raises(ArgumentError) { Ask::Agent::Middleware::ModelFallback.new(fallbacks: []) }
  end

  def test_requires_fallbacks_keyword
    assert_raises(ArgumentError) { Ask::Agent::Middleware::ModelFallback.new(fallbacks: []) }
  end

  # --- Pipeline integration ---

  def test_pipeline_knows_middleware
    pipeline = Ask::Agent::Middleware::Pipeline.new
    pipeline.use :model_fallback, fallbacks: [{ model: "claude-sonnet-4", provider: :anthropic }]
    assert pipeline.configured?
  end

  private

  def build_mw(fallbacks:, eligible_errors: nil)
    opts = { fallbacks: fallbacks }
    opts[:eligible_errors] = eligible_errors if eligible_errors
    Ask::Agent::Middleware::ModelFallback.new(**opts)
  end

  def stub_fallback_provider(mw, return_value)
    provider = Object.new
    provider.define_singleton_method(:chat) { |*args, **kwargs| return_value }
    mw.define_singleton_method(:build_fallback_provider) { |_| provider }
  end

  def stub_provider_raising(error)
    p = Object.new
    p.define_singleton_method(:chat) { |*args, **kwargs| raise error }
    p
  end

  def stub_provider_returning(value)
    p = Object.new
    p.define_singleton_method(:chat) { |*args, **kwargs| value }
    p
  end
end
