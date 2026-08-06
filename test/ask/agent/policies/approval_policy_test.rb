# frozen_string_literal: true

require_relative "../../../test_helper"

class ApprovalPolicyTest < Minitest::Test
  class ApprovalTool < Ask::Tool
    description "Needs approval"
    approval_required true
    def execute
      Ask::Result.ok(data: "ran")
    end
  end

  class AutoTool < Ask::Tool
    description "Auto"
    approval_required true
    auto_approvable true
    def execute
      Ask::Result.ok(data: "ran")
    end
  end

  class PlainTool < Ask::Tool
    description "No approval"
    def execute
      Ask::Result.ok(data: "ran")
    end
  end

  def setup
    @queue = Ask::Agent::ApprovalQueue.new
  end

  def build_policy(**opts)
    Ask::Agent::Policies::ApprovalPolicy.new(
      queue: @queue, tools: [ApprovalTool.new, AutoTool.new, PlainTool.new], **opts
    )
  end

  def tool_call(name, id: "call_1", arguments: {})
    Ask::Agent::ToolCallInfo.new(id: id, name: name, arguments: arguments)
  end

  # --- classification ---

  def test_plain_tool_proceeds
    policy = build_policy
    result = policy.before_tool_call(tool_call("plain"), {})
    assert_equal :proceed, result[:action]
    assert_empty @queue.pending_actions
  end

  def test_approval_required_tool_queues
    policy = build_policy
    result = policy.before_tool_call(tool_call("approval"), {})
    assert_equal :pending, result[:action]
    assert_kind_of Integer, result[:action_id]
    assert_equal "approval", @queue.pending_actions.first.tool_name
  end

  def test_queued_action_carries_args
    policy = build_policy
    result = policy.before_tool_call(tool_call("approval", arguments: { "to" => "x" }), {})
    action = @queue[result[:action_id]]
    assert_equal({ "to" => "x" }, action.args)
    assert_equal "call_1", action.tool_call_id
  end

  def test_auto_approvable_tool_queues_pending_without_rule
    policy = build_policy # no auto_approve rules on the queue
    result = policy.before_tool_call(tool_call("auto"), {})
    assert_equal :pending, result[:action]
    # Action carries the tool's declaration, but without a user rule the
    # queue's dual-signal keeps it pending
    assert @queue[result[:action_id]].auto_approvable
    assert @queue.any_pending?
  end

  # --- rule-based classification ---

  def test_rule_string_matches_tool_name
    policy = build_policy(require_approval: ["send_email"])
    assert_equal :pending, policy.before_tool_call(tool_call("send_email"), {})[:action]
  end

  def test_rule_regex_matches_tool_name
    policy = build_policy(require_approval: [/^email_/])
    assert_equal :pending, policy.before_tool_call(tool_call("email_send"), {})[:action]
  end

  def test_all_requires_approval_for_every_tool
    policy = build_policy(require_approval: :all)
    assert_equal :pending, policy.before_tool_call(tool_call("plain"), {})[:action]
  end

  def test_non_matching_rule_proceeds
    policy = build_policy(require_approval: ["send_email"])
    assert_equal :proceed, policy.before_tool_call(tool_call("plain"), {})[:action]
  end

  # --- permission rules ---

  def build_rules(&block)
    Ask::Agent::Policies::PermissionRules.new(&block)
  end

  def test_rules_deny_blocks
    policy = build_policy(rules: build_rules { deny :plain })
    result = policy.before_tool_call(tool_call("plain"), {})
    assert_equal :block, result[:action]
    assert_match(/Denied by permission rules/, result[:reason])
    assert_empty @queue.pending_actions
  end

  def test_rules_allow_proceeds_without_queueing
    policy = build_policy(rules: build_rules { allow :approval }) # beats approval_required
    result = policy.before_tool_call(tool_call("approval"), {})
    assert_equal :proceed, result[:action]
    assert_empty @queue.pending_actions
  end

  def test_rules_allow_beats_auto_approvable_declaration
    policy = build_policy(rules: build_rules { allow :auto })
    assert_equal :proceed, policy.before_tool_call(tool_call("auto"), {})[:action]
  end

  def test_rules_ask_queues_without_auto_approve
    policy = build_policy(rules: build_rules { ask :auto }) # beats auto_approvable
    result = policy.before_tool_call(tool_call("auto"), {})
    assert_equal :pending, result[:action]
    action = @queue.pending_actions.first
    refute action.auto_approvable
  end

  def test_rules_deny_beats_auto_approvable_declaration
    policy = build_policy(rules: build_rules { deny :auto })
    assert_equal :block, policy.before_tool_call(tool_call("auto"), {})[:action]
  end

  def test_dangerous_allow_rule_queues_as_pending
    policy = build_policy(rules: build_rules { allow :bash })
    result = policy.before_tool_call(tool_call("bash", arguments: "ls"), {})
    assert_equal :pending, result[:action]
  end

  def test_restricted_allow_rule_proceeds
    policy = build_policy(rules: build_rules { allow :bash, /^git status/ })
    result = policy.before_tool_call(tool_call("bash", arguments: "git status"), {})
    assert_equal :proceed, result[:action]
  end

  def test_no_matching_rule_falls_back_to_declarations
    policy = build_policy(rules: build_rules { allow :bash, /^git/ })
    # No rule matches "approval" → tool declaration applies.
    assert_equal :pending, policy.before_tool_call(tool_call("approval"), {})[:action]
  end

  # --- auto-approval dual signal ---

  def test_auto_approve_rule_enables_flagged_tool
    queue = Ask::Agent::ApprovalQueue.new(auto_approve: { "auto" => true })
    policy = Ask::Agent::Policies::ApprovalPolicy.new(
      queue: queue, tools: [AutoTool.new]
    )
    result = policy.before_tool_call(tool_call("auto"), {})
    assert_equal :pending, result[:action]
    # Tool declared auto-approvable AND user rule enabled → drained immediately
    assert_empty queue.pending_actions
  end

  def test_rule_on_non_flagged_tool_stays_queued
    queue = Ask::Agent::ApprovalQueue.new(auto_approve: { "approval" => true })
    policy = Ask::Agent::Policies::ApprovalPolicy.new(
      queue: queue, tools: [ApprovalTool.new]
    )
    result = policy.before_tool_call(tool_call("approval"), {})
    assert_equal :pending, result[:action]
    refute queue[result[:action_id]].auto_approvable
    assert queue.any_pending?
  end

  # --- duck-typed tools (no class declaration) ---

  def test_duck_typed_tool_requires_rule
    duck = Object.new
    duck.define_singleton_method(:name) { "duck_tool" }
    policy = Ask::Agent::Policies::ApprovalPolicy.new(queue: @queue, tools: [duck])
    assert_equal :proceed, policy.before_tool_call(tool_call("duck_tool"), {})[:action]

    policy = Ask::Agent::Policies::ApprovalPolicy.new(
      queue: @queue, tools: [duck], require_approval: ["duck_tool"]
    )
    assert_equal :pending, policy.before_tool_call(tool_call("duck_tool"), {})[:action]
  end
end
