# frozen_string_literal: true

module Ask
  module Agent
    module Extensions
      # Approval policy hook: classifies tool calls as approval-required and
      # routes them into an {Ask::Agent::ApprovalQueue}.
      #
      # Wire it as a +before_tool+ hook on a Session (or enable it with
      # `Session.new(approval: true)`), and any tool whose class declares
      # `approval_required true` — or whose name matches the policy's
      # rule-based lists — is queued for human approval instead of executed.
      # The agent receives a pending result and continues; the tool runs only
      # after a human approves it.
      #
      # @example
      #   queue = Ask::Agent::ApprovalQueue.new
      #   policy = Ask::Agent::Extensions::ApprovalPolicy.new(queue: queue)
      #   session = Ask::Agent::Session.new(
      #     model: "gpt-4o",
      #     tools: [SendEmail],
      #     hooks: { before_tool: [policy.method(:before_tool_call)] }
      #   )
      #
      #   # Later, when the user decides:
      #   session.approval_queue.approve_all
      class ApprovalPolicy
        # @param queue [Ask::Agent::ApprovalQueue] the queue actions go into.
        #   The queue owns the user-enabled auto-approval rules; this policy
        #   only reports each tool's own declaration.
        # @param require_approval [Array<String, Regexp>, :all, nil] extra
        #   rule-based classification on top of the tool's own declaration.
        #   Strings match tool names exactly, Regexps match against the name,
        #   and :all requires approval for every tool call.
        # @param tools [Array<Object>, nil] the session's resolved tool
        #   instances, used to read class-level declarations
        #   (`approval_required`, `auto_approvable`). When nil, only the
        #   rule-based lists classify calls.
        def initialize(queue:, require_approval: nil, tools: nil)
          @queue = queue
          @require_approval = require_approval
          @tools = Array(tools)
        end

        # Hook entry point — matches the +before_tool+ hook signature.
        #
        # @param tool_call [Ask::Agent::ToolCallInfo]
        # @param _context [Hash]
        # @return [Hash] {action: :proceed} to run, or
        #   {action: :pending, action_id:, reason:} to queue for approval
        def before_tool_call(tool_call, _context)
          return { action: :proceed } unless approval_required?(tool_call.name)

          auto_approvable = tool_auto_approvable?(tool_call.name)
          action_id = @queue.submit(
            tool_call_id: tool_call.id,
            tool_name: tool_call.name,
            args: tool_call.arguments,
            auto_approvable: auto_approvable,
            message: "Calling \"#{tool_call.name}\" requires approval"
          )

          { action: :pending, action_id: action_id, reason: "Tool '#{tool_call.name}' requires approval" }
        end

        private

        def approval_required?(tool_name)
          return true if @require_approval == :all

          rule_matches?(@require_approval, tool_name) || tool_declares_approval?(tool_name)
        end

        def rule_matches?(rules, tool_name)
          Array(rules).any? do |rule|
            rule == tool_name || (rule.is_a?(Regexp) && rule.match?(tool_name))
          end
        end

        def tool_declares_approval?(tool_name)
          tool = tool_for(tool_name)
          tool&.respond_to?(:approval_required?) && tool.approval_required?
        end

        def tool_auto_approvable?(tool_name)
          tool = tool_for(tool_name)
          tool&.respond_to?(:auto_approvable?) && tool.auto_approvable?
        end

        def tool_for(tool_name)
          @tools.find { |t| t.respond_to?(:name) && t.name == tool_name }
        end
      end
    end
  end
end
