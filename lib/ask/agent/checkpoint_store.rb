# frozen_string_literal: true

require "securerandom"

module Ask
  module Agent
    # Versioned, durable session checkpoints on any {Ask::State::Adapter}.
    #
    # Every checkpoint is a full session snapshot (the same payload
    # {Session#save} writes) stored under a sequential key. The adapter only
    # needs the minimal KV contract — +get+, +set+, +delete+ — so this works
    # with every state provider (SQLite, Redis, Postgres, MySQL) and with
    # custom adapters that implement nothing else. No list primitives are
    # required.
    #
    # Keys (session id + suffix):
    #   "<id>:checkpoint:<seq>"  — one key per checkpoint
    #   "<id>:checkpoint:head"   — the current seq (the active timeline)
    #
    # Rolling back moves the head pointer; later checkpoints are kept, so a
    # session can roll forward again (time travel). Forking copies the
    # checkpoints up to a point into a new session id — the branch diverges
    # from there.
    class CheckpointStore
      CHECKPOINT_KEY = ":checkpoint:"
      HEAD_KEY = ":checkpoint:head"

      # @param state_adapter [Ask::State::Adapter] backing store
      def initialize(state_adapter)
        @state = state_adapter
      end

      # @return [Ask::State::Adapter] the underlying adapter
      attr_reader :state

      # Append a checkpoint. The new checkpoint becomes the head.
      #
      # @param session_id [String]
      # @param data [Hash] session snapshot
      # @return [Integer] the new checkpoint seq
      def checkpoint(session_id, data)
        seq = (head(session_id) || 0) + 1
        @state.set(checkpoint_key(session_id, seq), data)
        @state.set(head_key(session_id), seq)
        seq
      end

      # @param session_id [String]
      # @return [Integer, nil] current head seq, or nil when the session has
      #   no checkpoints
      def head(session_id)
        @state.get(head_key(session_id))
      end

      # @param session_id [String]
      # @return [Array<Integer>] all checkpoint seqs, oldest first
      def history(session_id)
        current = head(session_id)
        current ? (1..current).to_a : []
      end

      # Load a checkpoint's data.
      #
      # @param session_id [String]
      # @param seq [Integer, nil] checkpoint seq; defaults to the head
      # @return [Hash, nil] the snapshot, or nil when it does not exist
      def load(session_id, seq: nil)
        seq ||= head(session_id)
        return nil unless seq

        @state.get(checkpoint_key(session_id, seq))
      end

      # Move the head pointer to an earlier (or later) checkpoint. Later
      # checkpoints are kept so the session can roll forward again.
      #
      # @param session_id [String]
      # @param seq [Integer]
      # @return [Integer] the seq rolled back to
      # @raise [ArgumentError] when the checkpoint does not exist
      def rollback(session_id, seq)
        raise ArgumentError, "no checkpoint #{seq}" unless @state.get(checkpoint_key(session_id, seq))

        @state.set(head_key(session_id), seq)
        seq
      end

      # Copy the checkpoints up to +at_seq+ into a new session id — a branch
      # that diverges from that point.
      #
      # @param session_id [String]
      # @param at_seq [Integer, nil] checkpoint to fork from; defaults to the
      #   head
      # @param new_id [String] id for the forked session (defaults to a new
      #   uuid)
      # @return [String] the forked session's id
      # @raise [ArgumentError] when the checkpoint does not exist
      def fork(session_id, at_seq: nil, new_id: SecureRandom.uuid)
        at_seq ||= head(session_id)
        raise ArgumentError, "no checkpoint #{at_seq}" unless at_seq && @state.get(checkpoint_key(session_id, at_seq))

        (1..at_seq).each do |seq|
          data = @state.get(checkpoint_key(session_id, seq))
          @state.set(checkpoint_key(new_id, seq), data)
        end
        @state.set(head_key(new_id), at_seq)
        new_id
      end

      # Remove every checkpoint for a session.
      #
      # @param session_id [String]
      # @return [void]
      def delete(session_id)
        history(session_id).each do |seq|
          @state.delete(checkpoint_key(session_id, seq))
        end
        @state.delete(head_key(session_id))
        nil
      end

      private

      def checkpoint_key(session_id, seq)
        "#{session_id}#{CHECKPOINT_KEY}#{seq}"
      end

      def head_key(session_id)
        "#{session_id}#{HEAD_KEY}"
      end
    end
  end
end
