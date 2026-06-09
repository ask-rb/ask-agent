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

  def test_load_nonexistent
    assert_nil @store.load("nonexistent")
  end

  def test_base_raises
    base = Ask::Agent::Persistence::Base.new
    assert_raises(NotImplementedError) { base.save("x", {}) }
    assert_raises(NotImplementedError) { base.load("x") }
    assert_raises(NotImplementedError) { base.delete("x") }
    assert_raises(NotImplementedError) { base.list }
  end
end
