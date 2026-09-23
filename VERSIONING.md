# Versioning — ask-agent

This file is this repository's canonical versioning policy. If any other
document (README, RELEASE.md, CONTRIBUTING.md, commit messages) disagrees
with it, this file wins.

## Scheme

Versions follow [Semantic Versioning 2.0.0](https://semver.org) as
`MAJOR.MINOR.PATCH`.

ask-agent is pre-1.0 (`0.y.z`). Until 1.0.0:

- **PATCH** (`0.40.22` → `0.40.23`) — bug fixes and other
  backwards-compatible corrections. No new features, no public API changes.
- **MINOR** (`0.40.22` → `0.41.0`) — new features **and**
  backwards-incompatible changes. Pre-1.0, a minor bump is how breaking
  changes are signaled (the role a major bump plays after 1.0.0): removed
  methods, changed signatures, changed defaults, and dependency jumps that
  break callers all ship in a minor.
- **MAJOR** (`0.y.z` → `1.0.0`) — reserved for the stability commitment of
  1.0.0 and for breaking changes after it.

After 1.0.0 the standard meanings apply: patch = fixes, minor =
backwards-compatible features, major = breaking changes.

### Sequential one-step patch increments

Patch numbers increase by exactly one per release. From `0.40.22` the next
patch is `0.40.23` — never `0.40.25`, never a skip, never a jump. Patch
numbers are never reused or decremented.

- A failed release attempt that published **nothing** may be retried at the
  same patch number.
- Once a version is on RubyGems it is immutable: any further change takes
  the next patch number.

### Patch digits range 0 through 9

Each digit of `MAJOR.MINOR.PATCH` ranges only from `0` to `9`. The patch
digit is a single digit: after `9` the next release rolls the minor digit
up by one and resets patch to `0` — `0.40.9` → `0.41.0`, never `0.40.10`.

### One-time bridge: 0.40.30 → 0.41.0

This repository already has `0.40.30` published (2026-09-23), a patch
number with two digits that the single-digit rule does not allow. Do not
rewrite it: `0.40.30` is immutable on RubyGems and its changelog heading
stays as-is. The next release must be `0.41.0`. This is a one-time bridge
to bring the patch line back under the single-digit rule — it does not
change the rule itself.

## Releases go through gemchain

Every `ask-*` gem — ask-agent included — and `yamine` is released through
[gemchain](https://github.com/ask-rb/gemchain), run from the `ask-rb`
workspace root. Never release by hand: no manual `gem build` / `gem push`,
no `rake release`, no hand-edited version bumps outside gemchain.

```bash
cd /Users/kaka/Code/ask-rb
gemchain guard ask-agent                  # blast radius: who depends on us
gemchain update ask-agent 0.40.23 --dry-run
gemchain update ask-agent 0.40.23 --test-only
gemchain update ask-agent 0.40.23
```

`gemchain` itself is not an `ask-*` gem, so the cascade cannot release it.
gemchain releases follow this same discipline **manually**: bump `VERSION`,
update the changelog, run tests, commit, `gem build` + `gem push`, `git
tag`, push.

### Dependency releases use the gemchain cascade

Releasing a dependency is never a single-gem event. `gemchain update` on the
dependency rewrites each dependent's gemspec constraint, re-runs that
dependent's tests, bumps its version by one patch, commits, publishes,
tags, and pushes — in topological order across the workspace. Never
hand-edit a dependent's constraint or release dependents separately; one
`gemchain update` on the dependency performs the whole cascade.

### Clean tree required

`git status` must be clean in this repository before a release starts.
Commit or stash work-in-progress first. A release may introduce only the
release's own changes: version bump, changelog entry, and any gemspec
constraint/lockfile updates the cascade makes.

## Release checklist

Every release, in this order:

1. **Clean tree** — `git status` clean in this repository.
2. **Version** — bump `lib/ask/agent/version.rb` by exactly one step
   (gemchain does this).
3. **Changelog** — move the `## [Unreleased]` entries under a new
   `## [x.y.z] - YYYY-MM-DD` heading; leave the empty `## [Unreleased]`
   section in place (see below).
4. **Tests** — full suite green: `bundle exec rake test`.
5. **Build** — `gem build ask-agent.gemspec` succeeds and the packaged file
   list looks right.
6. **Commit** — one release commit containing the version, changelog, and
   any constraint updates; nothing else.
7. **Tag** — `vX.Y.Z` on that commit, matching `version.rb` exactly.
8. **Publish** — `gem push` so RubyGems serves the new version.
9. **Push** — the commit and the tag are pushed to `origin`.

Steps 2, 4, 6, 7, 8, and 9 are executed by `gemchain update`; verify them
in the report rather than repeating them by hand.

### The agreement invariant

After every release, all four must name the same version:

- the published gem on rubygems.org
- `lib/ask/agent/version.rb` at `HEAD`
- the `vX.Y.Z` git tag
- the released changelog heading

Any mismatch — a published gem with no commit (orphaned release), a bumped
`version.rb` with no publish, a tag pointing elsewhere — is a broken
release. Fix it before starting the next one.

## Unreleased changelog workflow

`CHANGELOG.md` keeps a `## [Unreleased]` section at the top. Add entries
there as work lands, grouped under `### Added` / `### Changed` / `###
Fixed` / `### Deprecated` / etc. At release time, those entries move
underneath the new `## [x.y.z] - YYYY-MM-DD` heading; the `## [Unreleased]`
heading stays so the next cycle starts empty. Never publish a release whose
entries are still under `[Unreleased]`, and never rewrite history for
already-released versions.

## Examples

Starting from `0.40.22`:

- Fix a bug with no API change → `0.40.23` (patch).
- Add a new public method or option → `0.41.0` (minor).
- Remove or rename a public method → `0.41.0` (minor — breaking is allowed
  pre-1.0, but only ever in a minor).
- From `0.40.22`, **never** jump to `0.40.25` for a fix, and **never**
  release `0.42.0` for a one-line bugfix.
- Two fixes in a row → `0.40.23`, then `0.40.24` — one step each time.
- Dependency example: releasing `ask-session` runs
  `gemchain update ask-session <ver>` from the workspace root; the cascade
  rewrites ask-agent's gemspec constraint, re-runs this suite, bumps
  ask-agent by one patch, commits, publishes, tags, and pushes — no manual
  steps in this repository.
