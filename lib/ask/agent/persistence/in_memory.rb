# frozen_string_literal: true

module Ask
  module Agent
    module Persistence
      class InMemory < Base
        def initialize
          @store = {}
          @mutex = Mutex.new
        end

        def save(session_id, data)
          @mutex.synchronize { @store[session_id] = data }
        end

        def load(session_id)
          @mutex.synchronize { @store[session_id] }
        end

        def delete(session_id)
          @mutex.synchronize { @store.delete(session_id) }
        end

        def list
          @mutex.synchronize { @store.keys }
        end
      end
    end
  end
end
