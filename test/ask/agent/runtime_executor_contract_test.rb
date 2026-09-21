# frozen_string_literal: true

require_relative "../../test_helper"

class AgentRuntimeExecutorContractTest < Minitest::Test
  include Ask::Runtime::Testing::ExecutorContract

  class SuccessTool < Ask::Tool
    name "runtime_contract_success"

    def execute(**)
      Ask::Result.ok(data: "ok")
    end
  end

  class FailureTool < Ask::Tool
    name "runtime_contract_failure"

    def execute(**)
      Ask::Result.error(message: "failed")
    end
  end

  def test_agent_executor_conforms_to_runtime_contract
    executor = Ask::Agent::ToolExecutor.new(max_retries: 0, parallel: false)
    executor.instance_variable_set(:@last_tools, [SuccessTool.new, FailureTool.new])
    context_factory = ->(event_sink:, canceller: nil) do
      Ask::Runtime::ExecutionContext.new(
        session_id: "s_agent", turn: 1, event_sink: event_sink, canceller: canceller
      )
    end

    assert_conforms_to_runtime_contract(
      executor,
      success_call: build_call("runtime_contract_success", outcome: :success),
      failure_call: build_call("runtime_contract_failure", outcome: :failure),
      cancelled_call: build_call("runtime_contract_success", outcome: :cancelled),
      context_factory: context_factory
    )
  end

  private

  def build_call(tool_name, outcome:)
    Ask::Runtime::ToolCall.new(
      id: "tc_#{outcome}", tool_name: tool_name, input: {},
      session_id: "s_agent", turn: 1
    )
  end
end
