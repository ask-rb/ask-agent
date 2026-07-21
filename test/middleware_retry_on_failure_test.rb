# frozen_string_literal: true

require_relative "test_helper"

class MiddlewareRetryOnFailureTest < Minitest::Test
  def setup
    @middleware = Ask::Agent::Middleware::RetryOnFailure.new(max_retries: 3)
    @provider = stub
    @request = { model: "gpt-4o" }
  end

  def quiet_sleep
    @middleware.define_singleton_method(:sleep) { |_| }
  end

  def quiet_backoff
    @middleware.define_singleton_method(:compute_backoff) { |_| 0.001 }
  end

  def test_passthrough_on_success
    call_count = 0
    result = @middleware.around_request(@provider, @request) {
      call_count += 1
      "success"
    }
    assert_equal "success", result
    assert_equal 1, call_count
  end

  def test_retries_on_rate_limit
    quiet_sleep
    quiet_backoff
    call_count = 0

    assert_raises(Ask::RateLimitError) {
      @middleware.around_request(@provider, @request) {
        call_count += 1
        raise Ask::RateLimitError, "rate limited"
      }
    }
    assert_equal 3, call_count
  end

  def test_does_not_retry_on_unauthorized
    call_count = 0
    assert_raises(Ask::Unauthorized) {
      @middleware.around_request(@provider, @request) {
        call_count += 1
        raise Ask::Unauthorized, "bad key"
      }
    }
    assert_equal 1, call_count
  end

  def test_does_not_retry_on_model_not_found
    call_count = 0
    assert_raises(Ask::ModelNotFound) {
      @middleware.around_request(@provider, @request) {
        call_count += 1
        raise Ask::ModelNotFound, "unknown model"
      }
    }
    assert_equal 1, call_count
  end

  def test_does_not_retry_on_configuration_error
    call_count = 0
    assert_raises(Ask::ConfigurationError) {
      @middleware.around_request(@provider, @request) {
        call_count += 1
        raise Ask::ConfigurationError, "bad config"
      }
    }
    assert_equal 1, call_count
  end

  def test_retries_on_server_error
    quiet_sleep
    quiet_backoff
    call_count = 0

    assert_raises(Ask::ServerError) {
      @middleware.around_request(@provider, @request) {
        call_count += 1
        raise Ask::ServerError, "500"
      }
    }
    assert_equal 3, call_count
  end

  def test_retries_on_service_unavailable
    quiet_sleep
    quiet_backoff
    call_count = 0

    assert_raises(Ask::ServiceUnavailable) {
      @middleware.around_request(@provider, @request) {
        call_count += 1
        raise Ask::ServiceUnavailable, "503"
      }
    }
    assert_equal 3, call_count
  end

  def test_succeeds_on_retry
    quiet_sleep
    quiet_backoff
    call_count = 0

    result = @middleware.around_request(@provider, @request) {
      call_count += 1
      raise Ask::RateLimitError, "rate limited" if call_count < 3
      "success on attempt #{call_count}"
    }
    assert_equal "success on attempt 3", result
    assert_equal 3, call_count
  end

  def test_uses_retry_after_from_error
    quiet_sleep
    call_count = 0

    result = @middleware.around_request(@provider, @request) {
      call_count += 1
      if call_count < 3
        err = Ask::RateLimitError.new("rate limited")
        err.instance_variable_set(:@retry_after, 1.5)
        raise err
      end
      "done"
    }
    assert_equal "done", result
    assert_equal 3, call_count
  end

  def test_compute_backoff_exponential
    b1 = @middleware.send(:compute_backoff, 0)
    b2 = @middleware.send(:compute_backoff, 1)
    b3 = @middleware.send(:compute_backoff, 2)

    assert_operator b1, :>=, 1.0
    assert_operator b1, :<=, 2.0
    assert_operator b2, :>=, 2.0
    assert_operator b2, :<=, 3.0
    assert_operator b3, :>=, 4.0
    assert_operator b3, :<=, 5.0
  end

  def test_default_max_retries
    mw = Ask::Agent::Middleware::RetryOnFailure.new
    assert_equal 3, mw.instance_variable_get(:@max_retries)
  end

  def test_custom_max_retries
    mw = Ask::Agent::Middleware::RetryOnFailure.new(max_retries: 5)
    assert_equal 5, mw.instance_variable_get(:@max_retries)
  end

  def test_pipeline_integration_with_retry
    pipeline = Ask::Agent::Middleware::Pipeline.new
    pipeline.use :retry_on_failure, max_retries: 2

    provider = Object.new
    call_count = 0
    provider.define_singleton_method(:chat) do |*args, **kwargs|
      call_count += 1
      raise Ask::RateLimitError, "limit" if call_count < 2
      "ok"
    end

    request = { messages: [], model: "gpt-4o" }

    result = pipeline.invoke(provider, request) { provider.chat(request[:messages], model: request[:model]) }
    assert_equal "ok", result
    assert_equal 2, call_count
  end
end
