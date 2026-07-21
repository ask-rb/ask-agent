# frozen_string_literal: true

require_relative "test_helper"

class MiddlewareLogCallsTest < Minitest::Test
  def setup
    @log_stringio = StringIO.new
    @logger = Logger.new(@log_stringio)
    @middleware = Ask::Agent::Middleware::LogCalls.new(logger: @logger)
    @provider = stub
    @request = { model: "gpt-4o", tools: [], messages: [{ role: :user, content: "hi" }] }
  end

  def test_logs_successful_call
    Time.stubs(:now).returns(Time.new(2026, 1, 1, 12, 0, 0))

    @middleware.around_request(@provider, @request) { "ok" }

    log_output = @log_stringio.string
    assert_match(/LLM call starting/, log_output)
    assert_match(/LLM call completed/, log_output)
    assert_match(/model=gpt-4o/, log_output)
  end

  def test_logs_tool_count
    @request[:tools] = [stub, stub]

    @middleware.around_request(@provider, @request) { "ok" }

    log_output = @log_stringio.string
    assert_match(/tools=2/, log_output)
  end

  def test_logs_message_count
    @request[:messages] = [{ role: :user }, { role: :assistant }]

    @middleware.around_request(@provider, @request) { "ok" }

    log_output = @log_stringio.string
    assert_match(/messages=2/, log_output)
  end

  def test_logs_failed_call
    assert_raises(RuntimeError) {
      @middleware.around_request(@provider, @request) { raise "boom" }
    }

    log_output = @log_stringio.string
    assert_match(/LLM call starting/, log_output)
    assert_match(/LLM call failed/, log_output)
    assert_match(/RuntimeError/, log_output)
  end

  def test_uses_default_logger
    mw = Ask::Agent::Middleware::LogCalls.new
    assert mw.instance_variable_get(:@logger)
  end
end
