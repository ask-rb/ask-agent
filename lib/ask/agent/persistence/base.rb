# frozen_string_literal: true

module Ask
  module Agent
    module Persistence
      class Base
        def save(session_id, data)
          raise NotImplementedError
        end

        def load(session_id)
          raise NotImplementedError
        end

        def delete(session_id)
          raise NotImplementedError
        end

        def list
          raise NotImplementedError
        end
      end
    end
  end
end
