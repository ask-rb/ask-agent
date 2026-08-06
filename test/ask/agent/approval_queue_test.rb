# frozen_string_literal: true

require_relative "../../test_helper"

class ApprovalQueueTest < Minitest::Test
  def setup
    @approved = []
    @rejected = []
    @queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { @approved << action },
      on_reject: ->(action) { @rejected << action }
    )
  end

  # --- submit ---

  def test_submit_assigns_incrementing_ids
    id1 = @queue.submit(tool_call_id: "call_1", tool_name: "a", args: { "x" => 1 })
    id2 = @queue.submit(tool_call_id: "call_2", tool_name: "b")
    assert_equal 1, id1
    assert_equal 2, id2
  end

  def test_submit_stores_action_details
    id = @queue.submit(tool_call_id: "call_9", tool_name: "send_email", args: { "to" => "x@y.com" })
    action = @queue[id]
    assert_equal "call_9", action.tool_call_id
    assert_equal "send_email", action.tool_name
    assert_equal({ "to" => "x@y.com" }, action.args)
    assert_equal :pending, action.status
    assert_instance_of Time, action.submitted_at
  end

  def test_submit_defaults_auto_approvable_false
    id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    refute @queue[id].auto_approvable
  end

  # --- pending_actions ---

  def test_pending_actions_returns_only_pending_in_order
    @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.submit(tool_call_id: "call_2", tool_name: "b")
    assert_equal %w[a b], @queue.pending_actions.map(&:tool_name)
  end

  def test_pending_actions_empty_after_approval
    id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.approve(id)
    assert_empty @queue.pending_actions
  end

  def test_pending_predicate
    id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    assert @queue.pending?(id)
    @queue.approve(id)
    refute @queue.pending?(id)
  end

  def test_queue_pending_predicate
    refute @queue.any_pending?
    @queue.submit(tool_call_id: "call_1", tool_name: "a")
    assert @queue.any_pending?
  end

  # --- approve ---

  def test_approve_calls_on_approve_with_action
    id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.approve(id)
    assert_equal 1, @approved.size
    assert_equal id, @approved.first.id
    assert_equal :approved, @queue[id].status
  end

  def test_approve_multiple_in_id_order
    first_id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    second_id = @queue.submit(tool_call_id: "call_2", tool_name: "b")
    # Approve out of order — applied in id (submission) order
    @queue.approve(second_id, first_id)
    assert_equal %w[a b], @approved.map(&:tool_name)
  end

  def test_approve_unknown_id_is_noop
    result = @queue.approve(999)
    assert_empty result
    assert_empty @approved
  end

  def test_approve_all
    @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.submit(tool_call_id: "call_2", tool_name: "b")
    @queue.approve_all
    assert_equal %w[a b], @approved.map(&:tool_name)
    assert_empty @queue.pending_actions
  end

  def test_approve_idempotent
    id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.approve(id)
    @queue.approve(id)
    assert_equal 1, @approved.size
  end

  # --- reject ---

  def test_reject_calls_on_reject
    id = @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.reject(id)
    assert_equal 1, @rejected.size
    assert_equal :rejected, @queue[id].status
    assert_empty @approved
  end

  def test_reject_all
    @queue.submit(tool_call_id: "call_1", tool_name: "a")
    @queue.submit(tool_call_id: "call_2", tool_name: "b")
    @queue.reject_all
    assert_equal %w[a b], @rejected.map(&:tool_name)
    assert_empty @queue.pending_actions
  end

  # --- auto-approval (dual signal) ---

  def test_auto_approve_requires_action_flagged_and_rule_enabled
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { @approved << action },
      auto_approve: { "send_email" => true }
    )

    # Tool marked auto-approvable + rule enabled → applied immediately
    queue.submit(tool_call_id: "call_1", tool_name: "send_email", auto_approvable: true)
    assert_equal ["send_email"], @approved.map(&:tool_name)
    assert_empty queue.pending_actions
  end

  def test_auto_approve_requires_rule_enabled
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { @approved << action }
    )
    # Action marked auto-approvable but NO rule enabled → stays pending
    id = queue.submit(tool_call_id: "call_1", tool_name: "send_email", auto_approvable: true)
    assert_empty @approved
    assert queue.pending?(id)
  end

  def test_auto_approve_requires_action_flagged
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { @approved << action },
      auto_approve: { "send_email" => true }
    )
    # Rule enabled but action NOT auto-approvable → stays pending
    id = queue.submit(tool_call_id: "call_1", tool_name: "send_email", auto_approvable: false)
    assert_empty @approved
    assert queue.pending?(id)
  end

  def test_auto_approve_stops_at_manual_gate
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { @approved << action },
      auto_approve: { "safe" => true }
    )
    # Auto-eligible action submitted first applies; manual-gate action after
    # it stays pending and is NOT skipped past.
    queue.submit(tool_call_id: "call_1", tool_name: "safe", auto_approvable: true)
    queue.submit(tool_call_id: "call_2", tool_name: "manual", auto_approvable: false)
    queue.submit(tool_call_id: "call_3", tool_name: "safe", auto_approvable: true)

    # First safe applied; manual gate stops the drain; third stays pending
    assert_equal ["safe"], @approved.map(&:tool_name)
    assert_equal %w[manual safe], queue.pending_actions.map(&:tool_name)
  end

  def test_drain_single_flight_no_double_apply
    calls = 0
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { calls += 1 },
      auto_approve: { "safe" => true }
    )
    5.times { |i| queue.submit(tool_call_id: "call_#{i}", tool_name: "safe", auto_approvable: true) }
    assert_equal 5, calls
  end

  # --- apply failure leaves action retryable ---

  def test_apply_failure_restores_pending
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { raise "boom" }
    )
    id = queue.submit(tool_call_id: "call_1", tool_name: "a")
    assert_raises(RuntimeError) { queue.approve(id) }
    assert queue.pending?(id)
  end

  # --- reject after failed apply ---

  def test_reject_after_failed_apply
    queue = Ask::Agent::ApprovalQueue.new(
      on_approve: ->(action) { raise "boom" }
    )
    id = queue.submit(tool_call_id: "call_1", tool_name: "a")
    assert_raises(RuntimeError) { queue.approve(id) }
    queue.reject(id)
    assert_equal :rejected, queue[id].status
  end
end
