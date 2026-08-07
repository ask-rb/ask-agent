# frozen_string_literal: true

require "json"

module Ask
  module Agent
    # State-backed storage for large tool outputs, keeping them out of the
    # conversation transcript.
    #
    # When a tool result exceeds the session's offload threshold, the
    # executor stores the full output here and the transcript keeps a short
    # preview plus a reference the model can retrieve with the output_read
    # tool (and the web UI can fetch from the same store).
    #
    # Storage shape (pure KV — works with every Ask::State::Adapter backend
    # including custom get/set/delete adapters):
    #   output:<session_id>:<call_id>   — one key per offloaded output
    #   output:<session_id>:index       — JSON array of call ids (write order)
    #
    #   store = Ask::Agent::ToolOutputStore.new(state: adapter)
    #   store.store(session_id, "call_1", huge_output)
    #   store.fetch(session_id, "call_1")   # => huge_output
    #   store.delete(session_id)            # session cleanup
    class ToolOutputStore
      KEY_PREFIX = "output:"
      INDEX_SUFFIX = ":index"

      # @param state [Ask::State::Adapter] backing store
      # @param max_size [Integer] stored outputs are truncated to this many
      #   characters (with a truncation marker)
      def initialize(state:, max_size: 50_000)
        @state = state
        @max_size = max_size
        @mutex = Monitor.new
      end

      # @return [Ask::State::Adapter] the underlying adapter
      attr_reader :state

      # Store an output for a tool call (idempotent per call id — a later
      # store with the same call id replaces the earlier one).
      #
      # @param session_id [String]
      # @param call_id [String]
      # @param content [String]
      # @return [String] the stored content (possibly truncated)
      def store(session_id, call_id, content)
        stored = content.to_s
        stored = "#{stored[0, @max_size]}\n...(output truncated)" if stored.length > @max_size

        @mutex.synchronize do
          @state.set(entry_key(session_id, call_id), stored)
          index = load_index(session_id)
          @state.set(index_key(session_id), (index + [call_id]).uniq.to_json)
        end
        stored
      end

      # @param session_id [String]
      # @param call_id [String]
      # @return [String, nil] the stored output, or nil when absent
      def fetch(session_id, call_id)
        @state.get(entry_key(session_id, call_id))
      end

      # Remove every output for a session (called by Session#delete).
      #
      # @param session_id [String]
      # @return [void]
      def delete(session_id)
        @mutex.synchronize do
          load_index(session_id).each { |call_id| @state.delete(entry_key(session_id, call_id)) }
          @state.delete(index_key(session_id))
        end
        nil
      end

      private

      def load_index(session_id)
        raw = @state.get(index_key(session_id))
        raw ? JSON.parse(raw) : []
      end

      def entry_key(session_id, call_id)
        "#{KEY_PREFIX}#{session_id}:#{call_id}"
      end

      def index_key(session_id)
        "#{KEY_PREFIX}#{session_id}#{INDEX_SUFFIX}"
      end
    end
  end
end
