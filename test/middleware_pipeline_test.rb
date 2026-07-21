# frozen_string_literal: true

require_relative "test_helper"

# Concrete middleware classes for testing
$middleware_test_log = []

class TestLoggingMiddlewareA < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    $middleware_test_log << :a_before
    result = yield
    $middleware_test_log << :a_after
    result
  end
end

class TestLoggingMiddlewareB < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    $middleware_test_log << :b_before
    result = yield
    $middleware_test_log << :b_after
    result
  end
end

class TestModifyingMiddleware < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    request[:modified] = true
    yield
  end
end

class TestShortCircuitMiddleware < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    "short-circuit"
  end
end

class TestResultWrapMiddleware < Ask::Agent::Middleware::Base
  def around_request(provider, request)
    "wrapped-#{yield}"
  end
end

class MiddlewarePipelineTest < Minitest::Test
  def setup
    @pipeline = Ask::Agent::Middleware::Pipeline.new
  end

  def test_empty_pipeline_is_not_configured
    refute @pipeline.configured?
  end

  def test_pipeline_with_middleware_is_configured
    @pipeline.use :log_calls
    assert @pipeline.configured?
  end

  def test_use_with_symbol_resolves_builtin
    @pipeline.use :retry_on_failure, max_retries: 5
    assert @pipeline.configured?
  end

  def test_use_with_class
    @pipeline.use Ask::Agent::Middleware::LogCalls
    assert @pipeline.configured?
  end

  def test_use_with_invalid_symbol_raises
    assert_raises(ArgumentError) { @pipeline.use :nonexistent }
  end

  def test_use_with_invalid_class_raises
    assert_raises(ArgumentError) { @pipeline.use String }
  end

  def test_use_with_non_class_non_symbol_raises
    assert_raises(ArgumentError) { @pipeline.use "string" }
  end

  def test_invoke_passthrough_with_no_middleware
    result = @pipeline.invoke(stub, {}) { "direct-result" }
    assert_equal "direct-result", result
  end

  def test_invoke_chains_middleware_in_order
    $middleware_test_log.clear
    @pipeline.use TestLoggingMiddlewareA
    @pipeline.use TestLoggingMiddlewareB

    @pipeline.invoke(stub, {}) { $middleware_test_log << :inner; "done" }
    assert_equal [:a_before, :b_before, :inner, :b_after, :a_after], $middleware_test_log
  end

  def test_middleware_can_modify_request
    @pipeline.use TestModifyingMiddleware

    request = { original: true }
    captured = nil
    @pipeline.invoke(stub, request) { captured = request; "ok" }
    assert captured[:modified]
  end

  def test_middleware_can_short_circuit
    @pipeline.use TestShortCircuitMiddleware

    inner_called = false
    result = @pipeline.invoke(stub, {}) { inner_called = true; "inner" }
    assert_equal "short-circuit", result
    refute inner_called
  end

  def test_middleware_can_wrap_result
    @pipeline.use TestResultWrapMiddleware

    result = @pipeline.invoke(stub, {}) { "inner" }
    assert_equal "wrapped-inner", result
  end

  def test_middleware_chain_handles_errors
    @pipeline.use Ask::Agent::Middleware::LogCalls

    assert_raises(RuntimeError) {
      @pipeline.invoke(stub, {}) { raise "boom" }
    }
  end

  def test_iterates_entries
    @pipeline.use :log_calls
    @pipeline.use :retry_on_failure

    classes = []
    @pipeline.each { |entry| classes << entry[:klass] }
    assert_equal [Ask::Agent::Middleware::LogCalls, Ask::Agent::Middleware::RetryOnFailure], classes
  end

  def test_configuration_integration
    Ask::Agent.configure do |c|
      c.middleware.use :log_calls
      c.middleware.use :retry_on_failure, max_retries: 5
    end

    assert Ask::Agent.configuration.middleware.configured?
    entries = []
    Ask::Agent.configuration.middleware.each { |e| entries << e }
    assert_equal 2, entries.length
  ensure
    Ask::Agent.configuration.instance_variable_get(:@middleware).instance_variable_set(:@entries, [])
  end
end
