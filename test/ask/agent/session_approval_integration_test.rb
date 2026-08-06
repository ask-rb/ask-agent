# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

class SessionApprovalIntegrationTest < Minitest::Test
  include AgentTestHelpers

  class EmailTool < Ask::Tool
    description "Send an email"
    approval_required true
    param :to, type: :string, desc: "Recipient", required: true
    param :body, type: :string, desc: "Body", required: true

    def execute(to:, body:)
      Ask::Result.ok(data: "Email sent to #{to}")
    end
  end

  class SafeTool < Ask::Tool
    description "Safe read"
    def execute
      Ask::Result.ok(data: "safe result")
    end
  end

  class AutoEmailTool < Ask::Tool
    description "Auto email"
    approval_required true
    auto_approvable true
    param :to, type: :string, desc: "Recipient", required: true

    def execute(to:)
      Ask::Result.ok(data: "Auto email sent to #{to}")
    end
  end

  def build_chat_stub(sequence: [])
    chat = stub(
      model: "gpt-4o",
      model_id: "gpt-4o",
      messages: []
    )
    chat.stubs(:with_instructions).returns(chat)
    chat.stubs(:add_message).returns(nil)
    responses = sequence.map do |r|
      ResponseMessage.new(
        content: r[:content] || "",
        tool_calls: r[:tool_calls] || {},
        thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil
      )
    end
    # Sequence ask responses: each call returns the next response; the last
    # one repeats (the agent is done and the loop exits).
    chat.stubs(:ask).returns(*responses)
    chat
  end

  ResponseMessage = Data.define(:content, :tool_calls, :tool_results, :thinking, :input_tokens, :output_tokens, :cost) do
    def initialize(content:, tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
      super(content: content, tool_calls: tool_calls, tool_results: tool_results, thinking: thinking,
            input_tokens: input_tokens, output_tokens: output_tokens, cost: cost)
    end
    def tool_call? = !tool_calls.empty?
    def to_s = content.to_s
  end

  def stub_tool_call(id: "call_1", name: "email", arguments: '{"to":"x@y.com","body":"hi"}')
    Ask::Agent::ToolCallInfo.new(id: id, name: name, arguments: arguments)
  end

  # --- Session wiring ---

  def test_session_without_approval_has_nil_queue
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [])
    assert_nil s.approval_queue
  end

  def test_session_with_approval_true_has_queue
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], approval: true)
    assert_instance_of Ask::Agent::ApprovalQueue, s.approval_queue
  end

  def test_session_with_approval_hash_passes_policy_options
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [],
      approval: { require_approval: ["some_tool"], auto_approve: { "other" => true } }
    )
    assert_instance_of Ask::Agent::ApprovalQueue, s.approval_queue
  end

  def test_session_with_existing_queue_uses_it
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    queue = Ask::Agent::ApprovalQueue.new
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], approval: queue)
    assert_same queue, s.approval_queue
  end

  # --- End-to-end: approval-required tool is queued, not executed ---

  def test_approval_required_tool_is_queued_not_executed
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    email_tool = EmailTool.new
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [email_tool],
      approval: { auto_approve: {} }
    )

    # The session should not call the tool — it returns the interim reply
    response = s.run("Send an email to x")
    assert_equal "", response  # interim reply (empty content, tool call)

    # The action is queued, not executed
    assert_equal 1, s.approval_queue.pending_actions.size
    action = s.approval_queue.pending_actions.first
    assert_equal "email", action.tool_name
    assert s.pending_tools?
  end

  def test_approval_required_tool_runs_after_approve
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } },
      { content: "Email sent" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { auto_approve: {} }
    )
    s.run("Send an email to x")

    action = s.approval_queue.pending_actions.first
    s.approval_queue.approve(action.id)

    # After approval, the tool result is added and a follow-up runs
    refute s.pending_tools?
    assert_empty s.approval_queue.pending_actions
  end

  def test_approval_required_tool_rejected
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } },
      { content: "Cannot send" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { auto_approve: {} }
    )
    s.run("Send an email to x")

    action = s.approval_queue.pending_actions.first
    s.approval_queue.reject(action.id)

    refute s.pending_tools?
    assert_empty s.approval_queue.pending_actions
  end

  # --- End-to-end: auto-approvable tool with rule runs immediately ---

  def test_auto_approvable_tool_with_rule_runs
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "auto_email", arguments: '{"to":"x@y.com"}') } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [AutoEmailTool.new],
      approval: { auto_approve: { "auto_email" => true } }
    )
    s.run("Send auto email to x")

    # Auto-approvable + rule → drained immediately, no pending action
    assert_empty s.approval_queue.pending_actions
  end

  def test_auto_approvable_tool_without_rule_queues
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "auto_email", arguments: '{"to":"x@y.com"}') } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [AutoEmailTool.new],
      approval: { auto_approve: {} }
    )
    s.run("Send auto email to x")

    assert_equal 1, s.approval_queue.pending_actions.size
  end

  # --- Safe tools unaffected ---

  def test_safe_tool_runs_without_approval
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "safe", arguments: "{}") } },
      { content: "done" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [SafeTool.new],
      approval: { auto_approve: {} }
    )
    response = s.run("Do safe thing")
    assert_equal "done", response  # tool executed, loop continued
    assert_empty s.approval_queue.pending_actions
    refute s.pending_tools?
  end
end
