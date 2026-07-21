# frozen_string_literal: true

module Ask
  module Agent
    class Configuration
      attr_accessor :default_model, :default_max_turns, :compactor_enabled,
                    :compactor_threshold, :parallel_tool_execution, :max_tool_retries,
                    :prompt_caching

      # @return [Middleware::Pipeline] the middleware pipeline for provider calls
      attr_reader :middleware

      # @return [StreamTransforms::Pipeline] the stream transforms pipeline
      attr_reader :stream_transforms

      def initialize
        @default_model = "gpt-4o"
        @default_max_turns = 25
        @compactor_enabled = true
        @compactor_threshold = 0.8
        @parallel_tool_execution = true
        @max_tool_retries = 3
        @prompt_caching = false

        @middleware = Middleware::Pipeline.new
        @stream_transforms = StreamTransforms::Pipeline.new
        @scheduler_config = SchedulerConfig.new(self)
      end

      # @return [SchedulerConfig] DSL for defining recurring agent tasks
      def scheduler
        @scheduler_config
      end
    end
  end
end
