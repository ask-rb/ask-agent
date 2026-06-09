# frozen_string_literal: true

module Ask
  module Agent
    class Configuration
      attr_accessor :default_model, :default_max_turns, :compactor_enabled,
                    :compactor_threshold, :parallel_tool_execution, :max_tool_retries

      def initialize
        @default_model = "gpt-4o"
        @default_max_turns = 25
        @compactor_enabled = true
        @compactor_threshold = 0.8
        @parallel_tool_execution = true
        @max_tool_retries = 3
      end
    end
  end
end
