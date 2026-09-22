# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class LoopToolExecutorDispatchTest < Minitest::Test
  # A ToolExecutor stand-in that records which method the Loop dispatches to.
  class RecordingExecutor
    attr_reader :dispatched_to

    def initialize(parallel:)
      @parallel = parallel
      @dispatched_to = []
    end

    def execute(tool_calls, tools, hooks:, event_emitter:, session_id: nil, turn: nil, result_callback: nil, runtime_event_sink: nil)
      @dispatched_to << (tool_calls.empty? ? :execute_empty : :execute)
      return [] unless @parallel

      # mirror the real executor: parallel mode fans out to worker threads
      execute_parallel(tool_calls, tools, hooks, event_emitter, ToolAbortControllerStub.new) do |id, result|
        result_callback&.call(id, result)
      end
    end

    def execute_parallel(tool_calls, tools, hooks, event_emitter, sibling_abort, &result_callback)
      @dispatched_to << :execute_parallel
      tool_calls.keys.map { |id| {tool_name: "x", message: "m", status: "success", id: id} }
    end

  # minimal stand-in for the abort controller
  class ToolAbortControllerStub
    def aborted? = false
  end
  end

  def setup
    @loop = Ask::Agent::Loop.new(max_turns: 3)
  end

  def chat_with_tool_calls(tool_calls)
    calls = 0
    chat = Object.new
    chat.define_singleton_method(:add_message) { |**| nil }
    chat.define_singleton_method(:ask) do |_msg, attachments: nil, &block|
      calls += 1
      with_tools = calls == 1
      OpenStruct.new(
        content: "thinking",
        tool_calls: (with_tools ? tool_calls : {}),
        tool_results: {},
        input_tokens: 1,
        output_tokens: 1,
        cost: 0.0,
        tool_call?: with_tools && tool_calls.any?
      )
    end
    chat
  end

  def run_loop_with(executor, tool_calls)
    emitter = Object.new
    emitter.define_singleton_method(:emit) { |*| nil }
    @loop.run_turn(
      chat: chat_with_tool_calls(tool_calls),
      message: "run",
      tools: [],
      tool_executor: executor,
      compactor: nil,
      hooks: Ask::Agent::Hooks.new,
      event_emitter: emitter
    )
  end

  def test_loop_respects_sequential_execution
    executor = RecordingExecutor.new(parallel: false)
    run_loop_with(executor, { "call_1" => OpenStruct.new(name: "t", id: "call_1", arguments: "{}") })

    refute_includes executor.dispatched_to, :execute_parallel,
      "sequential sessions must not dispatch tools to parallel threads"
  end

  def test_loop_dispatches_parallel_execution_when_configured
    executor = RecordingExecutor.new(parallel: true)
    run_loop_with(executor, { "call_1" => OpenStruct.new(name: "t", id: "call_1", arguments: "{}") })

    assert_includes executor.dispatched_to, :execute_parallel
  end
end
