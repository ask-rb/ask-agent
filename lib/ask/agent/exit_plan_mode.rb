# frozen_string_literal: true

require "ask/tools/tool"
require "ask/result"

module Ask
  module Agent
    # Presents the model's plan for human approval at the end of plan mode.
    #
    # Called after research: submits the plan to the session's plan queue
    # and returns a pending result — the agent hands back the interim reply
    # and waits for a human decision. On approval, plan mode turns off and
    # the agent executes the plan; on rejection, it stays in plan mode with
    # the rejection feedback in the conversation.
    #
    # Injected into the session by `Session.new(plan_mode: true)`.
    class ExitPlanMode < Ask::Tool
      description "Submit your plan for human approval and leave plan mode. " \
                   "Call this when your research is done and you are ready to execute."

      param :plan, type: :string, desc: "The plan you propose to execute", required: true

      # @param plan_queue [Ask::Agent::ApprovalQueue] queue carrying plan
      #   approvals; the session wires approve/reject callbacks
      # @param on_submit [Proc, nil] called with the plan text when the plan
      #   is submitted (used to emit PlanProposed)
      def initialize(plan_queue:, on_submit: nil)
        @plan_queue = plan_queue
        @on_submit = on_submit
        super()
      end

      def execute(plan:)
        tool_call_id = Thread.current[:ask_agent_tool_call_id]
        @plan_queue.submit(
          tool_call_id: tool_call_id,
          tool_name: "exit_plan_mode",
          args: { plan: plan.to_s },
          auto_approvable: false,
          message: "Plan submitted for approval"
        )
        @on_submit&.call(plan.to_s)
        Ask::Result.pending("Plan submitted for approval — waiting for a human decision")
      end
    end
  end
end
