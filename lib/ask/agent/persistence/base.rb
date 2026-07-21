# frozen_string_literal: true

module Ask
  module Agent
    module Persistence
      # Session persistence backed by a generic {Ask::State::Adapter}.
      #
      # This wraps session data under namespaced keys so multiple sessions
      # can coexist in the same state backend alongside other data.
      #
      # @example With the default in-memory store
      #   store = Persistence::InMemory.new
      #   store.save("session-1", { messages: [...] })
      #   store.load("session-1")
      #
      # @example With a custom state adapter (e.g. Redis)
      #   store = Persistence::Base.new(
      #     state_adapter: MyRedisAdapter.new
      #   )
      #   store.save("session-1", data)
      class Base
        KEY_PREFIX = "ask:session:"
        INDEX_KEY = "ask:session:index"

        # @param state_adapter [Ask::State::Adapter] backend store (defaults to Memory)
        def initialize(state_adapter: nil)
          @state = state_adapter || Ask::State::Memory.new
        end

        # @return [Ask::State::Adapter] the underlying state adapter
        attr_reader :state

        # Persist a session.
        # @param session_id [String] the session identifier
        # @param data [Hash] the session data
        def save(session_id, data)
          @state.set(key(session_id), data)
          # Keep the index list unique — remove existing entry first then append
          @state.list_remove(INDEX_KEY, session_id)
          @state.list_append(INDEX_KEY, session_id)
        end

        # Load a session.
        # @param session_id [String] the session identifier
        # @return [Hash, nil] the session data, or nil if not found
        def load(session_id)
          @state.get(key(session_id))
        end

        # Delete a session.
        # @param session_id [String] the session identifier
        def delete(session_id)
          @state.delete(key(session_id))
          @state.list_remove(INDEX_KEY, session_id)
        end

        # List all stored session IDs.
        # @return [Array<String>] list of session IDs
        def list
          @state.list_range(INDEX_KEY, 0, -1)
        end

        private

        def key(session_id)
          "#{KEY_PREFIX}#{session_id}"
        end
      end
    end
  end
end
