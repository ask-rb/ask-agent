# frozen_string_literal: true

require_relative "../../test_helper"

module Ask
  module Agent
    class CheckpointStoreTest < Minitest::Test
      # Full-featured adapter (get/set/delete) recording calls.
      class RecordingAdapter
        attr_reader :data

        def initialize
          @data = {}
        end

        def get(key) = @data[key]
        def set(key, value, ttl: nil) = @data[key] = value
        def delete(key) = @data.delete(key)
      end

      # Minimal adapter: only get/set. Proves checkpointing never requires
      # list primitives or anything beyond the core KV contract.
      class MinimalAdapter
        def initialize
          @data = {}
        end

        def get(key) = @data[key]
        def set(key, value, ttl: nil) = @data[key] = value
      end

      def setup
        @adapter = RecordingAdapter.new
        @store = CheckpointStore.new(@adapter)
      end

      def test_checkpoint_writes_sequential_seqs_and_moves_head
        assert_equal 1, @store.checkpoint("s1", { turn: 1 })
        assert_equal 2, @store.checkpoint("s1", { turn: 2 })
        assert_equal 3, @store.checkpoint("s1", { turn: 3 })
        assert_equal 3, @store.head("s1")
        assert_equal [1, 2, 3], @store.history("s1")
      end

      def test_head_and_history_are_nil_and_empty_without_checkpoints
        assert_nil @store.head("s1")
        assert_empty @store.history("s1")
        assert_nil @store.load("s1")
      end

      def test_load_defaults_to_head_and_accepts_seq
        @store.checkpoint("s1", { turn: 1 })
        @store.checkpoint("s1", { turn: 2 })
        assert_equal({ turn: 2 }, @store.load("s1"))
        assert_equal({ turn: 1 }, @store.load("s1", seq: 1))
        assert_nil @store.load("s1", seq: 99)
      end

      def test_rollback_moves_head_but_keeps_later_checkpoints
        @store.checkpoint("s1", { turn: 1 })
        @store.checkpoint("s1", { turn: 2 })
        @store.checkpoint("s1", { turn: 3 })

        assert_equal 1, @store.rollback("s1", 1)
        assert_equal 1, @store.head("s1")
        assert_equal({ turn: 1 }, @store.load("s1"))

        # Time travel: later checkpoints are kept, so rolling forward works.
        assert_equal 3, @store.rollback("s1", 3)
        assert_equal({ turn: 3 }, @store.load("s1"))
      end

      def test_rollback_to_missing_checkpoint_raises
        @store.checkpoint("s1", { turn: 1 })
        error = assert_raises(ArgumentError) { @store.rollback("s1", 5) }
        assert_match(/no checkpoint 5/, error.message)
      end

      def test_fork_copies_checkpoints_into_new_id
        3.times { |i| @store.checkpoint("s1", { turn: i + 1 }) }

        forked_id = @store.fork("s1", at_seq: 2)

        refute_equal "s1", forked_id
        assert_equal 2, @store.head(forked_id)
        assert_equal [1, 2], @store.history(forked_id)
        assert_equal({ turn: 1 }, @store.load(forked_id, seq: 1))
        assert_equal({ turn: 2 }, @store.load(forked_id))
        # The original is untouched and keeps its full history.
        assert_equal 3, @store.head("s1")
        assert_equal [1, 2, 3], @store.history("s1")
      end

      def test_fork_defaults_to_head_and_accepts_new_id
        2.times { |i| @store.checkpoint("s1", { turn: i + 1 }) }
        assert_equal "branch-1", @store.fork("s1", new_id: "branch-1")
        assert_equal 2, @store.head("branch-1")
      end

      def test_fork_at_missing_checkpoint_raises
        @store.checkpoint("s1", { turn: 1 })
        assert_raises(ArgumentError) { @store.fork("s1", at_seq: 9) }
        # A session with no checkpoints at all cannot be forked.
        assert_raises(ArgumentError) { @store.fork("s2") }
      end

      def test_delete_removes_all_checkpoint_keys
        @store.checkpoint("s1", { turn: 1 })
        @store.checkpoint("s1", { turn: 2 })

        @store.delete("s1")

        assert_nil @store.head("s1")
        assert_empty @store.history("s1")
        assert_nil @store.load("s1")
        # No stray keys remain in the adapter.
        assert_empty @adapter.data.keys.grep(/s1/)
      end

      def test_sessions_are_isolated
        @store.checkpoint("s1", { turn: 1 })
        @store.checkpoint("s2", { turn: 1 })
        @store.checkpoint("s2", { turn: 2 })

        assert_equal [1], @store.history("s1")
        assert_equal [1, 2], @store.history("s2")
      end

      def test_works_with_minimal_get_set_adapter
        minimal = CheckpointStore.new(MinimalAdapter.new)

        minimal.checkpoint("s1", { turn: 1 })
        minimal.checkpoint("s1", { turn: 2 })
        minimal.rollback("s1", 1)
        forked = minimal.fork("s1", at_seq: 1)

        assert_equal 1, minimal.head("s1")
        assert_equal({ turn: 1 }, minimal.load("s1"))
        assert_equal 1, minimal.head(forked)
        assert_equal({ turn: 1 }, minimal.load(forked))
      end

      def test_concurrent_checkpointing_produces_unique_seqs
        threads = 8.times.map { |i| Thread.new { @store.checkpoint("s1", turn: i) } }
        threads.each(&:join)

        assert_equal (1..8).to_a, @store.history("s1")
      end
    end
  end
end
