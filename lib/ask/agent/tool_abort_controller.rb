# frozen_string_literal: true

module Ask
  module Agent
    class ToolAbortController
      def initialize
        @aborted = false
        @mutex = Mutex.new
      end

      def abort!
        @mutex.synchronize { @aborted = true }
      end

      def aborted?
        @mutex.synchronize { @aborted }
      end

      def reset!
        @mutex.synchronize { @aborted = false }
      end
    end
  end
end
