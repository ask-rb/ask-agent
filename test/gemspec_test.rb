# frozen_string_literal: true

require_relative "test_helper"

class GemspecTest < Minitest::Test
  def test_gemspec_is_valid
    spec = Gem::Specification.load(File.expand_path("../ask-agent.gemspec", __dir__))
    assert spec, "Could not load gemspec"
    assert_kind_of Gem::Specification, spec
    assert spec.name.to_s.start_with?("ask-")
    assert spec.version.to_s > "0"
    refute_empty spec.summary.to_s
    refute_empty spec.authors.to_s
  end

  def test_gemspec_has_license
    spec = Gem::Specification.load(File.expand_path("../ask-agent.gemspec", __dir__))
    assert spec.license
  end
end
