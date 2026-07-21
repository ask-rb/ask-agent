# frozen_string_literal: true

module Ask
  module Agent
    module Persistence
      # In-memory session persistence. Backed by {Ask::State::Memory}.
      # Data is lost when the process exits.
      class InMemory < Base
        def initialize
          super(state_adapter: Ask::State::Memory.new)
        end
      end
    end
  end
end
