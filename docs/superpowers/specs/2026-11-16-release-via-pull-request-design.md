# Releasing through a pull request (Hulder port): design

**Date:** 2026-11-16
**Status:** In progress
**Canonical design:** Muninn's
([`michaelrigart/muninn`, `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`](https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md)),
signed off by Michael on 2026-11-16. Its goals, anti-goals, design, tests, documentation and
acceptance apply here unchanged. This document records only how Hulder differs.
**Supersedes in part:** Hulder's distribution design
(`docs/superpowers/specs/2026-11-03-hulder-distribution-design.md`), on the same points as the
canonical design supersedes Muninn's: the anti-goal "The release script pushes to `main` only its
own release commit (the changelog section), plus the tag", and step 3 of "Releasing": the push of
the release commit to `main` and "Recovering an unpushed release commit".

## Why

Hulder's `scripts/release` pushes "Release <version>" straight to `main`, which the rulesets
described in the canonical design have refused since 2026-11-14. Hulder's next release would fail
at that push, as Tafl's did.

## What Hulder takes

Muninn's `scripts/release` and `scripts/tests/test-release-dry-run`, as they stand on Muninn's
`fix/release-via-pr` once they pass Codex's pre-merge review, ported whole rather than
reimplemented (Michael, 2026-11-16: "all release scripts should resemble each other as much as
possible"). The plan names the Muninn commit the port is taken from.

Before this change Hulder's two files already equal Muninn's on `main` (`56c3e8b`) apart from the
differences below. That still holds after the port.

## Differences from Muninn

Names, the only differences the canonical design allows:

| | Muninn | Hulder |
|---|---|---|
| Repository | `michaelrigart/muninn` | `michaelrigart/hulder` |
| Temporary folder | `muninn-release.XXXXXX` | `hulder-release.XXXXXX` |
| App, project, scheme | `Muninn.app`, `Muninn.xcodeproj`, `Muninn` | `Hulder.app`, `Hulder.xcodeproj`, `Hulder` |
| Release asset | `Muninn-<version>.zip` | `Hulder-<version>.zip` |
| Cask template, cask | `scripts/muninn.rb.template`, `Casks/muninn.rb` | `scripts/hulder.rb.template`, `Casks/hulder.rb` |
| Tap commit message | `muninn <version>` | `hulder <version>` |

In the test, besides those names:

- **No zap cases.** Muninn's `zap_is_settings_only` helper and its four cases stay Muninn's, as the
  canonical design says. They check Muninn's own zap stanza (its settings folder alone); Hulder's
  cask zaps its Application Support folder and preferences, which they would reject.
- **One fixture string.** Case "a: the section holds only the fixture's text" checks that the
  printed section lacks a line from the repository's own `CHANGELOG.md`: Muninn's
  "Muninn records calls", Hulder's "Hulder v1: hide other apps".

The port is checked by mapping Muninn's names to Hulder's in Muninn's two files and diffing them
with Hulder's: the diff shows only the zap cases and the fixture string.

## Documentation

As the canonical design's "Documentation", in Muninn's wording with Hulder's names, so the
repositories' docs stay alike. Hulder keeps its own `design/render` sentence, and "Michael" where
Muninn says "the maintainer":

- `README.md`, "Releasing": the release commit goes through a pull request that the script opens
  and merges as admin; `gh` must use a login with the `repo` scope of an admin account; a failed
  run says where it stopped, and `--version` resumes it.
- `AGENTS.md`: the "Release" command line says it pushes a release branch and merges its pull
  request; a "Release flow" line after the "Distribution design" line names this document.
- The distribution design gains one line under its header pointing here for the release flow. Its
  text is not rewritten.
- No `CHANGELOG.md` entry: nothing changes for users.

The parallel line `fix/accessibility-grant` may edit `README.md`, `AGENTS.md` and `CHANGELOG.md`.
This change touches only the lines named above, so whichever merges second rebases cleanly.

## Acceptance

1. Muninn's two files, names mapped, differ from Hulder's only as described under "Differences
   from Muninn".
2. `scripts/tests/test-release-dry-run` passes on Michael's Mac, every case, and the changelog
   unit tests pass.
3. `scripts/release --dry-run` passes there and creates nothing on git or GitHub.
4. CI passes on the pull request.
5. After the merge, Hulder's next real release, run by Michael, lands, tags and publishes in one
   run and ends on `main` level with origin, with no `release/<version>` left.

Cross-repository: the Muninn, Hulder, Linger, Tafl and Skald pull requests are all opened before
any is merged, and Muninn's merges first.
