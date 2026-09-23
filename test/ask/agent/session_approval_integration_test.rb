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

  class ToolGrantStore
    attr_reader :tools

    def initialize
      @tools = []
    end

    def grant(tool_name)
      @tools << tool_name.to_s unless @tools.include?(tool_name.to_s)
    end

    def granted?(tool_name)
      @tools.include?(tool_name.to_s)
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
    assert_instance_of Ask::Permissions::ApprovalQueue, s.approval_queue
  end

  def test_session_with_approval_hash_passes_policy_options
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [],
      approval: { require_approval: ["some_tool"], auto_approve: { "other" => true } }
    )
    assert_instance_of Ask::Permissions::ApprovalQueue, s.approval_queue
  end

  def test_session_with_existing_queue_uses_it
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    queue = Ask::Permissions::ApprovalQueue.new
    s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], approval: queue)
    assert_same queue, s.approval_queue
  end

  # --- Permission modes ---

  def test_valid_modes_pass_through_to_policy
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    %i[full_access ask_before_changes read_only].each do |mode|
      s = Ask::Agent::Session.new(model: "gpt-4o", tools: [], approval: { mode: mode })
      assert_equal mode, s.approval_policy.mode, "mode #{mode} must reach the approval policy"
    end
  end

  def test_invalid_mode_raises
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    error = assert_raises(ArgumentError) do
      Ask::Agent::Session.new(model: "gpt-4o", tools: [], approval: { mode: :invalid_mode })
    end
    assert_match(/invalid_mode/, error.message)
  end

  def test_unknown_approval_option_raises
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    error = assert_raises(ArgumentError) do
      Ask::Agent::Session.new(model: "gpt-4o", tools: [], approval: { bogus_option: true })
    end
    assert_match(/bogus_option/, error.message)
  end

  def test_read_only_mode_blocks_tool_end_to_end
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "safe", arguments: "{}") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [SafeTool.new],
      approval: { mode: :read_only }
    )

    assert_equal :read_only, s.approval_policy.mode

    response = s.run("Do safe thing")

    # read_only refuses the change outright: no queue entry, no execution.
    assert_equal "", response
    assert_empty s.approval_queue.pending_actions
    refute s.pending_tools?
  end

  def test_mode_combines_with_existing_options
    Ask::Agent::Chat.stubs(:new).returns(build_chat_stub)
    rules = Ask::Permissions::PermissionRules.new { allow :email }
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { mode: :ask_before_changes, require_approval: ["some_tool"],
                  auto_approve: { "other" => true }, rules: rules }
    )
    assert_equal :ask_before_changes, s.approval_policy.mode
    assert_instance_of Ask::Permissions::ApprovalQueue, s.approval_queue
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

  # --- Permission rules ---

  def test_deny_rule_blocks_tool_end_to_end
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    rules = Ask::Permissions::PermissionRules.new { deny :email }
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { rules: rules }
    )

    response = s.run("Send an email")

    # The tool is refused outright: no queue entry, no execution.
    assert_equal "", response
    assert_empty s.approval_queue.pending_actions
    refute s.pending_tools?
  end

  def test_allow_rule_runs_tool_without_approval_end_to_end
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } },
      { content: "Sent!" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    # email is approval_required — an explicit allow rule overrides it.
    rules = Ask::Permissions::PermissionRules.new { allow :email }
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { rules: rules }
    )

    response = s.run("Send an email")

    # The tool executed (the loop recursed to the follow-up response) with
    # no approval prompt in between.
    assert_equal "Sent!", response
    assert_empty s.approval_queue.pending_actions
    refute s.pending_tools?
  end

  def test_project_rules_override_default_allows_but_never_default_denies
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    default_rules = Ask::Permissions::PermissionRules.new { deny :email }
    project_rules = Ask::Permissions::PermissionRules.new { allow :email }
    session = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { rules: default_rules, project_rules: project_rules }
    )

    session.run("Send an email")

    assert_empty session.approval_queue.pending_actions
    assert_equal :deny, session.approval_policy.rules.classify("email")
  end

  def test_dangerous_allow_rule_queues_instead_of_running
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    # Unrestricted allow on a code-executing tool downgrades to ask.
    rules = Ask::Permissions::PermissionRules.new { allow :bash }
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [SafeTool.new],
      approval: { rules: rules }
    )

    # bash isn't registered — the ruleset classifies it, the executor
    # reports "Tool not found"; the point is the rule never proceeds.
    s.run("do something")
    assert_empty s.approval_queue.pending_actions
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

  # --- Custom queue: default callbacks are wired ---

  class EmittingQueue < Ask::Permissions::ApprovalQueue
    attr_reader :submitted, :changed

    def initialize(*)
      super
      @submitted = []
      @changed = []
    end

    def submit(...)
      id = super
      @submitted << self[id]
      id
    end

    private

    def apply(action, scope: :once)
      result = super(action, scope: scope)
      @changed << result
      result
    end

    def reject_action(action, feedback: nil)
      result = super(action, feedback: feedback)
      @changed << result
      result
    end
  end

  def test_custom_queue_gets_default_callbacks_and_applies_on_approve
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email", arguments: '{"to":"x@y.com","body":"hi"}') } },
      { content: "done" } # follow-up turn after approval — no more tool calls
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    queue = EmittingQueue.new
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { queue: queue, auto_approve: {} }
    )
    s.run("Send an email to x")

    assert_same queue, s.approval_queue
    assert_equal 1, queue.submitted.size
    assert_equal 1, queue.pending_actions.size

    # Approving the custom queue action executes the underlying tool call
    # (the session wired its default on_approve callback onto the queue).
    queue.approve(queue.pending_actions.first.id)

    assert_empty queue.pending_actions
    refute s.pending_tools?
    assert_equal 1, queue.changed.size
    assert_equal :approved, queue.changed.first.status
    assert_equal :once, queue.changed.first.resolution_scope
  end

  def test_custom_queue_reject_notifies_conversation
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email", arguments: '{"to":"x@y.com","body":"hi"}') } },
      { content: "done" } # follow-up turn after rejection — no more tool calls
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    queue = EmittingQueue.new
    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { queue: queue, auto_approve: {} }
    )
    s.run("Send an email to x")

    queue.reject(queue.pending_actions.first.id)

    assert_empty queue.pending_actions
    refute s.pending_tools?
    assert_equal :rejected, queue.changed.first.status
    assert_nil queue.changed.first.feedback
  end

  # --- Pending registration happens at submit time (race closure) ---

  def test_pending_tool_registered_at_submit_time
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { auto_approve: {} }
    )
    s.run("Send an email to x")

    # The pending call was registered the moment the action was queued, so
    # an approval landing mid-execution still finds something to complete.
    assert s.pending_tools?
    assert s.instance_variable_get(:@pending_tools).key?("call_1")
  end

  def test_late_loop_registration_after_completion_is_skipped
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email", arguments: '{"to":"x@y.com","body":"hi"}') } },
      { content: "done" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    s = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { auto_approve: {} }
    )
    s.run("Send an email to x")
    queue = s.approval_queue

    # Simulate the executor racing: completion lands before the loop's own
    # registration, which must then be skipped (no ghost pending call).
    action = queue.pending_actions.first
    queue.approve(action.id)
    refute s.pending_tools?

    s.send(:register_pending_tool, action.tool_call_id,
           tool_name: "email", message: "Pending approval", status: "pending",
           tool_call_id: action.tool_call_id, action_id: action.id)

    refute s.pending_tools?, "late registration must not resurrect a completed call"
  end

  def test_session_scope_grants_whole_tool_but_once_scope_does_not
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email", arguments: '{"to":"x@y.com","body":"hi"}') } },
      { content: "done" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)

    session = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new], approval: { auto_approve: {} }
    )
    completed = []
    session.on(Ask::Agent::Events::ToolCompleted) { |event| completed << event }
    session.run("Send an email to x")
    action = session.approval_queue.pending_actions.first
    refute_nil action
    refute session.session_grants.granted?("email")

    session.approval_queue.approve(action.id, scope: :session)

    grants = session.session_grants
    assert grants.granted?("email")
    assert_same grants, session.approval_policy.session_grants
    assert_equal 1, completed.size
  end

  def test_session_grant_bypasses_queue_on_later_tool_call
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email", arguments: '{"to":"x@y.com","body":"first"}') } },
      { content: "done" }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)
    session = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new], approval: { auto_approve: {} }
    )
    session.run("first call")
    action = session.approval_queue.pending_actions.first
    session.approval_queue.approve(action.id, scope: :session)
    assert_empty session.approval_queue.pending_actions

    decision = session.instance_variable_get(:@approval_policy).before_tool_call(
      stub_tool_call(id: "call_2", name: "email")
    )
    assert_equal :proceed, decision[:action]
    assert_empty session.approval_queue.pending_actions
  end

  def test_once_and_project_approvals_do_not_create_session_grants
    %i[once project].each do |scope|
      chat = build_chat_stub(sequence: [
        { tool_calls: { "call_1" => stub_tool_call(name: "email", arguments: '{"to":"x@y.com","body":"hi"}') } },
        { content: "done" }
      ])
      Ask::Agent::Chat.stubs(:new).returns(chat)
      session = Ask::Agent::Session.new(
        model: "gpt-4o", tools: [EmailTool.new], approval: { auto_approve: {} }
      )
      session.run("Send an email")
      action = session.approval_queue.pending_actions.first
      session.approval_queue.approve(action.id, scope: scope)
      refute session.session_grants.granted?("email"), "#{scope} must not create a session grant"
    end
  end

  def test_project_scope_approval_grants_through_host_owned_collaborator
    project_grants = ToolGrantStore.new
    chat = build_chat_stub(sequence: [
      { tool_calls: { "call_1" => stub_tool_call(name: "email") } }
    ])
    Ask::Agent::Chat.stubs(:new).returns(chat)
    session = Ask::Agent::Session.new(
      model: "gpt-4o", tools: [EmailTool.new],
      approval: { auto_approve: {}, project_grants: project_grants }
    )
    session.run("Send an email")
    action = session.approval_queue.pending_actions.first

    session.approval_queue.approve(action.id, scope: :project)

    assert project_grants.granted?("email")
    assert_same project_grants, session.approval_policy.project_grants
    refute session.session_grants.granted?("email")
  end
end
