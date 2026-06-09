# frozen_string_literal: true

module Ask
  module Agent
    class Hooks
      def initialize(hooks = {})
        @before_tool = Array(hooks[:before_tool])
        @after_tool = Array(hooks[:after_tool])
      end

      def run_before_tool(tool_call, context)
        result = nil
        @before_tool.each do |hook|
          result = hook.call(tool_call, context)
          break if result.is_a?(Hash) && result[:action] != :proceed
        end
        result
      end

      def run_after_tool(tool_call, result, context)
        final = nil
        @after_tool.each do |hook|
          final = hook.call(tool_call, result, context)
          break if final.is_a?(Hash) && final[:action] == :block
        end
        final
      end
    end
  end
end
