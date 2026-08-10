# frozen_string_literal: true

module Ask
  module Agent
    # A queue of tool actions awaiting human approval.
    #
    # When an agent calls a tool that requires approval, the action is queued
    # instead of executed — the agent gets a pending result and continues.
    # The user approves or rejects actions later, in bulk or one-by-one.
    #
    #   queue = Ask::Agent::ApprovalQueue.new
    #   id = queue.submit(tool_call_id: "call_1", tool_name: "send_email",
    #                     args: { "to" => "x@y.com" }, auto_approvable: false)
    #   queue.pending_actions   # => [{id: 1, tool_name: "send_email", ...}]
    #   queue.approve(1)        # applies action 1 via the on_approve callback
    #   queue.reject(1)
    #
    # Auto-approval is a dual signal: the action must be marked
    # +auto_approvable+ (by the tool) AND the queue must have a matching
    # auto-approval rule enabled by the user. Otherwise the action queues for
    # human review.
    #
    # Actions are applied in id order and the drainer never applies past a
    # non-auto-approvable (manual) gate — nothing is silently approved.
    class ApprovalQueue
      # One queued action.
      #
      # @!attribute [r] id
      #   @return [Integer] sequential id assigned by the queue
      # @!attribute [r] tool_call_id
      #   @return [String] the original tool call id from the LLM
      # @!attribute [r] tool_name
      #   @return [String] tool name
      # @!attribute [r] args
      #   @return [Hash] arguments to pass to the tool when applied
      # @!attribute [r] auto_approvable
      #   @return [Boolean] per-action verdict (tool's declaration)
      # @!attribute [r] status
      #   @return [Symbol] :pending, :applying, :approved, :rejected
      # @!attribute [r] submitted_at
      #   @return [Time]
      # @!attribute [r] message
      #   @return [String, nil] human-readable description of the action
      Action = Data.define(:id, :tool_call_id, :tool_name, :args,
                           :auto_approvable, :status, :submitted_at, :message)

      # Create a new approval queue.
      #
      # @param on_approve [Proc, nil] called with an {Action} when it is
      #   approved and applied. The session wires this to execute the real
      #   tool call.
      # @param on_reject [Proc, nil] called with an {Action} when it is
      #   rejected. The session wires this to notify the conversation.
      # @param auto_approve [Hash{String => Boolean}, nil] user-enabled
      #   auto-approval rules keyed by tool name. An action is auto-applied
      #   only when its tool is listed here with +true+ AND the action itself
      #   is marked auto_approvable.
      # @!attribute [rw] on_approve
      #   Called with an {Action} when it is approved and applied. The
      #   session wires this to execute the real tool call; can be replaced
      #   after construction (e.g. by queue subclasses that also emit events).
      # @!attribute [rw] on_reject
      #   Called with an {Action} when it is rejected.
      # @!attribute [rw] on_submit
      #   Called with the new {Action} when it is submitted — BEFORE the
      #   auto-approval drain runs, so subscribers can register the pending
      #   call before it is applied. The session wires this to register the
      #   pending tool call, closing the race where an approval lands while
      #   the executor is still in flight.
      attr_accessor :on_approve, :on_reject, :on_submit

      def initialize(on_approve: nil, on_reject: nil, auto_approve: nil, on_submit: nil)
        @on_approve = on_approve
        @on_reject = on_reject
        @on_submit = on_submit
        @auto_approve = auto_approve || {}
        @actions = {}
        @next_id = 1
        @mutex = Mutex.new
        @draining = false
      end

      # Queue a tool action for approval.
      #
      # @param tool_call_id [String] original tool call id from the LLM
      # @param tool_name [String] tool name
      # @param args [Hash] arguments for the tool
      # @param auto_approvable [Boolean] whether the tool permits auto-approval
      # @param message [String, nil] human-readable description
      # @return [Integer] the action id
      def submit(tool_call_id:, tool_name:, args: {}, auto_approvable: false, message: nil)
        action = @mutex.synchronize do
          action = Action.new(
            id: @next_id,
            tool_call_id: tool_call_id,
            tool_name: tool_name,
            args: args || {},
            auto_approvable: auto_approvable,
            status: :pending,
            submitted_at: Time.now,
            message: message
          )
          @next_id += 1
          @actions[action.id] = action
          action
        end

        # Notify BEFORE the drain: an auto-approvable action is applied
        # (and possibly completed) inside drain, and listeners need to
        # observe the submission first.
        @on_submit&.call(action)

        drain
        action.id
      end

      # All actions still awaiting a decision, in id order.
      #
      # @return [Array<Action>]
      def pending_actions
        @mutex.synchronize do
          @actions.values.select { |a| a.status == :pending }.sort_by(&:id)
        end
      end

      # @param id [Integer]
      # @return [Boolean] whether the action is still awaiting a decision
      def pending?(id)
        @mutex.synchronize do
          a = @actions[id]
          a && a.status == :pending
        end
      end

      # @return [Boolean] true while at least one action awaits a decision
      def any_pending?
        pending_actions.any?
      end

      # Look up an action by id.
      #
      # @param id [Integer]
      # @return [Action, nil]
      def [](id)
        @mutex.synchronize { @actions[id] }
      end

      # Approve specific actions (by id), applying them in id order.
      #
      # @param ids [Array<Integer>]
      # @return [Array<Action>] the actions that were approved
      def approve(*ids)
        actions = ids.flatten.filter_map { |id| @mutex.synchronize { @actions[id] } }
        actions.select! { |a| a.status == :pending }
        actions.sort_by!(&:id)
        actions.each { |a| apply(a) }
        actions
      end

      # Reject specific actions (by id).
      #
      # @param ids [Array<Integer>]
      # @return [Array<Action>] the actions that were rejected
      def reject(*ids)
        actions = ids.flatten.filter_map { |id| @mutex.synchronize { @actions[id] } }
        actions.select! { |a| a.status == :pending }
        actions.sort_by!(&:id)
        actions.each { |a| reject_action(a) }
        actions
      end

      # Approve all currently pending actions, in id order.
      #
      # @return [Array<Action>]
      def approve_all
        approve(*pending_actions.map(&:id))
      end

      # Reject all currently pending actions, in id order.
      #
      # @return [Array<Action>]
      def reject_all
        reject(*pending_actions.map(&:id))
      end

      private

      # Apply eligible pending actions in id order, stopping at the first
      # action that is NOT auto-eligible (a manual gate) — nothing is
      # silently applied past a human review point. Single-flight guard so
      # concurrent drains cannot double-apply.
      def drain
        return if @mutex.synchronize { @draining }
        @mutex.synchronize { @draining = true }

        begin
          loop do
            action = @mutex.synchronize do
              @actions.values.select { |a| a.status == :pending }
                .sort_by(&:id)
                .first
            end
            break unless action

            if auto_approvable?(action)
              apply(action)
            else
              break # manual gate — stop, never skip ahead
            end
          end
        ensure
          @mutex.synchronize { @draining = false }
        end
      end

      def auto_approvable?(action)
        action.auto_approvable && @auto_approve[action.tool_name] == true
      end

      def apply(action)
        claimed = @mutex.synchronize do
          return false unless action.status == :pending
          @actions[action.id] = action.with(status: :applying)
        end
        @on_approve&.call(claimed)
        @mutex.synchronize do
          @actions[action.id] = claimed.with(status: :approved)
        end
        true
      rescue StandardError
        # Failed apply: leave the action pending so the user can retry or
        # reject it. Re-raise so the caller (approve/drain) surfaces it.
        @mutex.synchronize do
          @actions[action.id] = action.with(status: :pending) if @actions[action.id]&.status == :applying
        end
        raise
      end

      def reject_action(action)
        return false unless @mutex.synchronize { action.status == :pending }
        @on_reject&.call(action)
        @mutex.synchronize do
          @actions[action.id] = action.with(status: :rejected)
        end
        true
      end
    end
  end
end
