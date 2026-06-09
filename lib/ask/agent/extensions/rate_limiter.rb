# frozen_string_literal: true

module Ask
  module Agent
    module Extensions
      class RateLimiter
        def initialize(max_calls_per_minute: 20, max_tool_calls_per_turn: 5)
          @max_calls_per_minute = max_calls_per_minute
          @max_tool_calls_per_turn = max_tool_calls_per_turn
          @turn_calls = 0
          @minute_window = []
          @mutex = Mutex.new
        end

        def before_tool_call(tool_call, _context)
          now = Time.now

          @mutex.synchronize do
            @turn_calls += 1

            if @turn_calls > @max_tool_calls_per_turn
              return { action: :block, reason: "Exceeded #{@max_tool_calls_per_turn} tool calls per turn" }
            end

            @minute_window << now
            @minute_window.reject! { |t| now - t > 60 }

            if @minute_window.size > @max_calls_per_minute
              return { action: :block, reason: "Exceeded #{@max_calls_per_minute} tool calls per minute" }
            end
          end

          { action: :proceed }
        end

        def reset_turn!
          @mutex.synchronize { @turn_calls = 0 }
        end
      end
    end
  end
end
