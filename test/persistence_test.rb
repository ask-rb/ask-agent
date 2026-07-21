# frozen_string_literal: true

require_relative "test_helper"

class PersistenceTest < Minitest::Test
  def setup
    @store = Ask::Agent::Persistence::InMemory.new
  end

  def test_save_and_load
    data = { id: "s1", messages: [{ role: "user", content: "hi" }], metadata: { model: "gpt-4o" } }
    @store.save("s1", data)
    loaded = @store.load("s1")
    assert_equal "hi", loaded[:messages].first[:content]
  end

  def test_delete
    @store.save("s1", { id: "s1" })
    @store.delete("s1")
    assert_nil @store.load("s1")
  end

  def test_list
    @store.save("a", { id: "a" })
    @store.save("b", { id: "b" })
    assert_equal %w[a b].sort, @store.list.sort
  end

  def test_list_excludes_deleted
    @store.save("a", { id: "a" })
    @store.save("b", { id: "b" })
    @store.delete("a")
    assert_equal %w[b], @store.list
  end

  def test_load_nonexistent
    assert_nil @store.load("nonexistent")
  end

  def test_base_defaults_to_memory
    base = Ask::Agent::Persistence::Base.new
    base.save("test", { key: "value" })
    assert_equal "value", base.load("test")[:key]
    assert_equal %w[test], base.list
  end

  def test_base_with_custom_adapter
    custom = Class.new(Ask::State::Adapter) do
      def initialize
        @data = {}
        @index = []
      end
      def get(key) = @data[key]
      def set(key, value, ttl: nil)
        @data[key] = value
        @index << key.sub("ask:session:", "") if key.start_with?("ask:session:")
      end
      def delete(key)
        @data.delete(key)
        @index.delete(key.sub("ask:session:", ""))
      end
      def list_range(key, start = 0, stop = -1)
        return @index if key == "ask:session:index"
        @data[key].is_a?(Array) ? @data[key][start..stop] : []
      end
      def list_append(key, value)
        (@data[key] ||= []) << value
      end
      def list_remove(key, value)
        (@data[key] || []).delete(value) ? 1 : 0
      end
    end.new

    base = Ask::Agent::Persistence::Base.new(state_adapter: custom)
    base.save("s1", { msg: "hello" })
    assert_equal "hello", base.load("s1")[:msg]
    assert_equal %w[s1], base.list
  end

  def test_list_deduplicates
    @store.save("a", { id: "a" })
    @store.save("a", { id: "a" })
    # Same ID saved twice should only appear once in the index
    assert_equal %w[a], @store.list
  end
end
