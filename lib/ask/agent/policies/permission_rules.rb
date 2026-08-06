# frozen_string_literal: true

require "json"

module Ask
  module Agent
    module Policies
      # Persisted, matchable allow/ask/deny patterns for tool calls.
      #
      # Rules classify a tool call before it executes or prompts:
      #
      #   rules = Ask::Agent::Policies::PermissionRules.new do |r|
      #     r.allow :bash, /^git (pull|push|status)/
      #     r.ask   :bash, /^rm -rf/
      #     r.deny  :write, %r{/\.env(\.local)?$}
      #     r.ask   :destroy, :all
      #   end
      #
      #   session = Ask::Agent::Session.new(
      #     model: "gpt-4o",
      #     approval: { rules: rules }
      #   )
      #
      # Classification is first-match-wins, in declaration order: :allow runs
      # the tool, :ask queues it for human approval, :deny blocks it. Rules
      # take precedence over a tool's own `approval_required` / `auto_approvable`
      # declarations — they are explicit user intent.
      #
      # Dangerous-rule guard: an :allow rule for a code-executing tool (bash,
      # code, repl) whose argument pattern is unrestricted would let the model
      # run anything without asking. Such rules are downgraded to :ask unless
      # the ruleset was created with `auto_allow_dangerous: true` — "approve
      # once, remember the pattern" must not become "approve everything".
      class PermissionRules
        # A single rule: tool pattern + optional argument pattern + decision.
        Rule = Data.define(:tool_pattern, :argument_pattern, :decision) do
          def matches?(tool_name, arguments)
            tool_matches?(tool_name) && argument_matches?(arguments)
          end

          def tool_matches?(tool_name)
            case tool_pattern
            when :all then true
            when Regexp then tool_pattern.match?(tool_name.to_s)
            else tool_pattern.to_s == tool_name.to_s
            end
          end

          def argument_matches?(arguments)
            return true if argument_pattern.nil?

            text = arguments.is_a?(Hash) ? JSON.generate(arguments) : arguments.to_s
            case argument_pattern
            when Regexp then argument_pattern.match?(text)
            else text.include?(argument_pattern.to_s)
            end
          end

          def universal?
            argument_pattern.nil?
          end
        end

        # Tools that execute arbitrary code — an unrestricted :allow rule on
        # any of these is dangerous.
        DANGEROUS_TOOLS = %i[bash code repl].freeze

        # @param auto_allow_dangerous [Boolean] keep unrestricted :allow
        #   rules on code-executing tools (default false — they downgrade to
        #   :ask)
        def initialize(auto_allow_dangerous: false, &block)
          @auto_allow_dangerous = auto_allow_dangerous
          @rules = []
          instance_eval(&block) if block
        end

        # DSL — declare rules in priority order (first match wins).
        def allow(tool_pattern, argument_pattern = nil)
          add(:allow, tool_pattern, argument_pattern)
        end

        def ask(tool_pattern, argument_pattern = nil)
          add(:ask, tool_pattern, argument_pattern)
        end

        def deny(tool_pattern, argument_pattern = nil)
          add(:deny, tool_pattern, argument_pattern)
        end

        # @return [Array<Rule>] declared rules, in order
        def rules = @rules.dup

        # Classify a tool call.
        #
        # @param tool_name [String]
        # @param arguments [Hash, String, nil] tool arguments (hash or JSON)
        # @return [Symbol, nil] :allow, :ask, :deny — or nil when no rule
        #   matches
        def classify(tool_name, arguments = nil)
          rule = @rules.find { |r| r.matches?(tool_name, arguments) }
          return nil unless rule

          if rule.decision == :allow && dangerous?(rule) && !@auto_allow_dangerous
            :ask
          else
            rule.decision
          end
        end

        # @return [Array<Rule>] rules that would allow unrestricted execution
        #   of a code-executing tool
        def dangerous_rules
          @rules.select { |r| dangerous?(r) }
        end

        private

        def add(decision, tool_pattern, argument_pattern)
          @rules << Rule.new(tool_pattern, argument_pattern, decision)
        end

        def dangerous?(rule)
          return false unless rule.decision == :allow && rule.universal?

          rule.tool_pattern == :all || DANGEROUS_TOOLS.any? { |t| rule.tool_matches?(t) }
        end
      end
    end
  end
end
