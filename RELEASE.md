# Release Process — ask-agent

Version numbers, bump rules, and the release invariants are governed by
[VERSIONING.md](VERSIONING.md), this repository's canonical versioning
policy.

## Prerequisites

- All tests pass: `bundle exec rake test`
- CHANGELOG.md is updated with the release entries
- Runtime dependencies are published on rubygems.org — in particular
  `ask-session` must exist at a version satisfying `>= 0.1.0`, or
  `gem install ask-agent` will fail to resolve
- You have push access to rubygems.org

## Release Steps

1. Update the version in `lib/ask/agent/version.rb`
2. Update CHANGELOG.md with the new version and date
3. Run tests: `bundle exec rake test`
4. Build: `bundle exec rake build`
5. Publish: `bundle exec rake release`

## Quick Reference

```bash
# Release
cd ask-agent
bundle exec rake release
```

## VCR Cassette Policy (if applicable)

For gems that use VCR cassettes in tests:

- Always check cassettes for leaked API keys before committing
- Cassettes older than 30 days should be re-recorded before release
- To re-record: delete cassette files and run tests with API keys configured
