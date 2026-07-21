# frozen_string_literal: true

require_relative "../../test_helper"

class SystemContextTest < Minitest::Test
  class SimpleSource < Ask::Agent::ContextSource
    key "test/simple"

    def initialize(content)
      @content = content
    end

    def load
      @content
    end

    def baseline(content)
      "Content: #{content}"
    end

    def update(prev, curr)
      "Changed from #{prev} to #{curr}"
    end
  end

  def test_empty_context_renders_empty
    ctx = Ask::Agent::SystemContext.new([])
    assert_equal "", ctx.render
  end

  def test_single_source_renders_baseline
    ctx = Ask::Agent::SystemContext.new([SimpleSource.new("hello")])
    assert_includes ctx.render, "Content: hello"
  end

  def test_multiple_sources_combined
    s1 = Class.new(Ask::Agent::ContextSource) { key "test/first"; def load; @content; end; def baseline(v); "Content: #{v}"; end }.new
    s1.instance_variable_set(:@content, "first")
    s2 = Class.new(Ask::Agent::ContextSource) { key "test/second"; def load; @content; end; def baseline(v); "Content: #{v}"; end }.new
    s2.instance_variable_set(:@content, "second")

    ctx = Ask::Agent::SystemContext.new([s1, s2])
    rendered = ctx.render
    assert_includes rendered, "Content: first"
    assert_includes rendered, "Content: second"
  end

  def test_no_changes_initially
    ctx = Ask::Agent::SystemContext.new([SimpleSource.new("hello")])
    assert_nil ctx.changes
  end

  def test_change_detected_after_new_source_value
    source = SimpleSource.new("old")
    ctx = Ask::Agent::SystemContext.new([source])
    assert_nil ctx.changes

    source.instance_variable_set(:@content, "new")
    changes = ctx.changes
    refute_nil changes
    assert_includes changes.first, "Changed from old to new"
  end

  def test_no_change_when_value_stays_same
    source = SimpleSource.new("stable")
    ctx = Ask::Agent::SystemContext.new([source])
    3.times do
      assert_nil ctx.changes
    end
  end

  def test_multiple_changes_detected
    s1 = SimpleSource.new("a")
    s2 = SimpleSource.new("x")
    ctx = Ask::Agent::SystemContext.new([s1, s2])

    s1.instance_variable_set(:@content, "b")
    s2.instance_variable_set(:@content, "y")
    changes = ctx.changes
    assert_equal 2, changes.length
  end

  def test_access_source_by_key
    source = SimpleSource.new("test")
    ctx = Ask::Agent::SystemContext.new([source])
    assert_equal source, ctx["test/simple"]
    assert_nil ctx["nonexistent"]
  end

  def test_source_key_uniqueness
    s1 = Class.new(Ask::Agent::ContextSource) { key "test/a"; def load; "a"; end; def baseline(v); v; end }.new
    s2 = Class.new(Ask::Agent::ContextSource) { key "test/b"; def load; "b"; end; def baseline(v); v; end }.new
    ctx = Ask::Agent::SystemContext.new([s1, s2])
    assert_equal "test/a", ctx["test/a"].key
  end

  def test_baseline_nil_returns_nil_omitted
    source = Class.new(Ask::Agent::ContextSource) do
      key "test/nil_baseline"
      def load; "val"; end
      def baseline(v); nil; end
    end.new

    ctx = Ask::Agent::SystemContext.new([source])
    rendered = ctx.render
    refute_includes rendered, "test/nil_baseline"
  end
end

class ContextSourcesTest < Minitest::Test
  def setup
    @registry = skill_registry
  end

  def test_instructions_source
    source = Ask::Agent::ContextSources::Instructions.new("You are a helper.")
    assert_equal "core/instructions", source.key
    assert_equal "You are a helper.", source.load
    assert_equal "You are a helper.", source.baseline("You are a helper.")
  end

  def test_instructions_handles_nil
    source = Ask::Agent::ContextSources::Instructions.new(nil)
    assert_equal "", source.load
  end

  def test_skills_list_source_with_registry
    source = Ask::Agent::ContextSources::SkillsList.new(@registry)
    listing = source.load
    assert_includes listing, "test_skill"
  end

  def test_skills_list_source_nil_registry
    source = Ask::Agent::ContextSources::SkillsList.new(nil)
    assert_equal "", source.load
    assert_nil source.baseline("")
  end

  def test_always_active_skills_source
    source = Ask::Agent::ContextSources::AlwaysActiveSkills.new(@registry)
    content = source.load
    # Our test skill doesn't have always: true, so should be empty
    assert_equal "", content
    assert_nil source.baseline("")
  end

  def test_date_source
    source = Ask::Agent::ContextSources::Date.new
    assert_equal "core/date", source.key
    assert_equal Date.today.iso8601, source.load
    assert_includes source.baseline(Date.today.iso8601), "Today"
  end

  def test_date_update_when_changed
    source = Ask::Agent::ContextSources::Date.new
    update_text = source.update("2026-07-21", "2026-07-22")
    assert_includes update_text, "2026-07-21"
    assert_includes update_text, "2026-07-22"
  end

  def test_context_source_key_not_set_returns_nil
    source = Class.new(Ask::Agent::ContextSource).new
    assert_nil source.key rescue nil
  end

  private

  def skill_registry
    # Build a minimal fake registry
    skill = OpenStruct.new(
      name: "test_skill",
      description: "A test",
      instructions: "Do the test thing",
      metadata: {},
      siblings: {},
      tags: [],
      source: "/tmp/test",
      to_prompt_entry: "- **test_skill**: A test"
    )
    registry = OpenStruct.new(
      names: ["test_skill"],
      skills: { "test_skill" => skill },
      format_for_prompt: "\n## Available Skills\n\n- **test_skill**: A test\n\n",
      always_active_skills: []
    )
    def registry.[](name); skills[name]; end
    registry
  end
end
