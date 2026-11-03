# Hulder distribution — design

**Date:** 2026-11-03
**Owner:** Michael Rigart
**Status:** In progress ([PR #2](https://github.com/michaelrigart/hulder/pull/2)). Signed off by the controller on 2026-11-03 under Michael's overnight delegation
("I need you to finalize everything for me while I'm asleep"), after Codex's spec review; for
Michael to confirm.
**Template:** Linger's distribution design (`michaelrigart/linger`,
`docs/superpowers/specs/2026-11-01-linger-distribution-design.md`), which Michael asked to follow.
This document repeats what applies to Hulder, so it can be planned on its own. It states where
Hulder differs.

## Why

Hulder v1 works, but only as a local build. Its ad-hoc signature changes with every build, so
every rebuild and reinstall needs the Accessibility permission granted again. During
acceptance that meant a new grant after each fix. There is also no way to install or upgrade
Hulder except by building it from source.

Michael wants the same distribution Linger has:
- Hulder installable with Homebrew;
- releases he can cut in one step;
- CI on every change;
- a signing identity that keeps the Accessibility grant across rebuilds.

## Goals

- `brew install --cask michaelrigart/tap/hulder` installs Hulder, and `brew upgrade` upgrades
  it.
- One command on Michael's Mac cuts a release. It sets the version, updates the changelog,
  builds, signs, verifies, packages, tags, publishes the GitHub release and updates the cask.
- The Accessibility grant survives rebuilds and upgrades.
- CI tests and builds every pull request and every push to `main`.
- The artwork can be regenerated from sources in the repository.

## Non-goals

- Developer ID signing and notarization. They need the paid Apple Developer Program, which
  Michael declined for Linger. The same holds here.
- Mac App Store submission.
- Automatic updates inside the app. Homebrew handles upgrades.
- Signing in CI. The certificate's private key stays on Michael's Mac.
- Intel Macs. Releases are for Apple silicon only.
- Supporting macOS before 27. Hulder's targets stay at macOS 27.

## Anti-goals

- The cask must not strip the quarantine attribute or otherwise bypass Gatekeeper.
- No certificate, private key or token in the repository or in CI.
- The release script pushes to `main` only its own release commit (the changelog section),
  plus the tag. Only Michael runs it.
- No machine-specific paths or settings in the repository. It is public.
- No release may contain the Debug-only probe.

## Decisions (Michael's)

- **Same as Linger** (2026-11-03): signing, versions, Homebrew tap, changelog format, design
  sources in the repository, and Apple silicon only, as decided for Linger on 2026-11-01.
- **CI runs on GitHub's `xcode-27` image** (2026-11-03). Linger runs on `macos-26` with
  Xcode 26, but that image has no Xcode 27 (checked 2026-11-03), and Hulder needs Xcode 27 for
  its macOS 27 targets. GitHub now names its newest image after the Xcode major version:
  `xcode-27` runs macOS 27 with Xcode 27.0, 27.1 and a 27.2 release candidate. Its changelog
  calls it generally available since 2026-10-15; the image's README still says "preview".

## How it works

### Versions

- The version is the local time when the release script starts, `date +%Y%m%d-%H%M`, for
  example `20261103-1430`. There is no `v` prefix.
- It is the tag name, the GitHub release title, part of the asset name
  (`Hulder-<version>.zip`) and the cask's `version`.
- The app gets it at build time:
  - `MARKETING_VERSION=<version>` becomes `CFBundleShortVersionString`, which Settings ›
    About and Copy Diagnostics already show.
  - `CURRENT_PROJECT_VERSION=<digits only, YYYYMMDDHHMM>` becomes `CFBundleVersion`, which
    macOS compares as a number.
- `project.yml` today hard-codes `CFBundleShortVersionString: "0.1.0"` and
  `CFBundleVersion: "1"`. They become `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.
  Builds outside the release script show `dev` and build `0`.

### Signing

- `project.yml` sets `DEVELOPMENT_TEAM` to Michael's Personal Team ID, the same team Linger
  uses. Signing is manual, with the identity `Apple Development`, for Debug and Release. A Team
  ID is a public identifier: it is embedded in every signed build.
- macOS ties the Accessibility grant to the app's designated requirement. With a team
  certificate, that requirement names the certificate (its common name and Apple's
  intermediate) rather than a hash of one build, so the grant is expected to survive rebuilds
  and upgrades. Whether a renewed certificate keeps the same common name, and with it the
  grant, isn't measured.
  - Measured on 2026-11-03 (macOS 27.2): a team-signed Debug rebuild with a different CDHash
    and the team-signed Release build both launched with listing and reordering available and
    no new grant.
- Hardened Runtime stays on (`ENABLE_HARDENED_RUNTIME`, `--options=runtime`). Hulder has no
  entitlements, and a Release build must have none, `get-task-allow` included.
- Anyone without the certificate (CI, contributors) builds ad hoc by adding
  `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to `xcodebuild`.
- Scripts pick the signing identity by Team ID, not by the bare name `Apple Development`, so
  another team's development certificate on the same Mac is never used.
- **First check for the builder,** as for Linger: manual signing with this identity and no
  provisioning profile. If it fails, stop and bring it to Michael.
- **What the switch costs once.** The first team-signed build has a new designated
  requirement, so Accessibility is granted once more. Two more things may need doing once,
  and acceptance checks both:
  - the security-scoped bookmark for the menu bar folder may need the folder picked again;
  - launch at login may need registering again. Hulder already registers when macOS reports
    the item as not found.
  - Measured on 2026-11-03: one new Accessibility grant at the switch from ad hoc. The menu bar
    folder did not need picking again, and Hulder still showed in Login Items.
- MenuBarAgent's hiding assertion needs a signed app bundle in `/Applications`. A team
  signature is still a signed bundle, and the cask installs to `/Applications`.

### Verifying a built app

`scripts/verify-app <path-to-Hulder.app> [<expected-version>]` is used by CI and by the release
script. It fails unless:

- the signature verifies (`codesign --verify --strict`);
- the app has no entitlements: `codesign -d --entitlements` shows none or an empty dictionary
  (`project.yml` points at an entitlements file holding an empty dictionary);
- `LSUIElement` is true and the bundle identifier is `com.michaelrigart.hulder`;
- the executable contains no probe: neither the `-HulderProbe` flag nor the probe's usage text
  appears in it. The log category named `probe` is compiled into every build and doesn't count;
- when a version is given, `CFBundleShortVersionString` equals it and `CFBundleVersion` equals
  its digits.

`scripts/tests/test-verify-app` checks that the verifier rejects a tampered copy, as Linger's
does.

### CI

`.github/workflows/ci.yml` runs on pull requests and on pushes to `main`:

- `runs-on: xcode-27`, with an Xcode 27 release selected explicitly: 27.1 today. Michael builds
  with 27.2, which the image only has as a release candidate. If Hulder doesn't build or pass its
  tests with 27.1, CI selects the 27.2 release candidate, and the workflow says why. v1 code is
  not changed to suit an older compiler *(the controller's call, 2026-11-03)*;
- `permissions: contents: read`, and a concurrency group that cancels superseded runs;
- every third-party action pinned to a full commit SHA, with the version in a comment;
- XcodeGen from the repository's `mise.toml`, through the mise action.

Steps:
1. the changelog tool's tests;
2. `swift test --package-path Packages/HulderCore`;
3. `swift test --package-path Packages/HulderPlatform27`;
4. `mise exec -- xcodegen generate`;
5. a Release build for Apple silicon, signed ad hoc;
6. `scripts/verify-app` on the product, then the verifier's own test.

Unlike Linger's CI, this one runs on the macOS Hulder targets, so both suites run, not only the
core. The runner has no Accessibility grant and no menu bar session. A test that needs either
is a defect in the test: fix it so it doesn't depend on the machine, rather than skipping it in
CI.

### Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), in Linger's
format:

- a short preamble saying versions are `YYYYMMDD-HHMM` release times, not compatibility
  promises;
- `## [Unreleased]` at the top, which every pull request with a user-visible change adds to,
  under `### Added`, `### Changed`, `### Fixed` or `### Removed`;
- one `## [<version>] - <YYYY-MM-DD>` section per release;
- link definitions at the bottom: `[Unreleased]` compares the latest version with `HEAD`, each
  version compares with the one before it, and the first links to its release.

The first `Unreleased` section records Hulder v1 and this distribution work. `scripts/changelog.py`
and its tests come over from Linger, renamed.

### Releasing

`scripts/release`, run by Michael on his Mac, follows Linger's script step for step:

1. **Checks:**
   - no local changes;
   - `gh` signed in;
   - the team's Apple Development identity in the keychain.

   A new release must also be on `main`, level with `origin/main`, with entries under
   `## [Unreleased]`. A resumed release must be on a commit on `origin/main` whose changelog
   already has the version's section, and, if the tag exists, on the tagged commit.
   `--dry-run` skips the branch and `origin/main` checks.
2. Computes the version, or takes `--version <version>` to resume. When resuming with an
   existing tag (locally or on `origin`), both tags and `HEAD` must be the same commit.
   Otherwise the script stops and says which commit to check out.
3. **New release only:** moves the `Unreleased` entries under `## [<version>] - <date>`,
   updates the link definitions, commits `Release <version>` and pushes it to `main`.
   `--dry-run` prints the section instead.
   - **Recovering an unpushed release commit.** A push that fails undoes the local release
     commit, as Linger's script does, so nothing unpushed is left behind. A run interrupted
     between the commit and the push leaves it in place, and `--version <version>` resumes
     from it. It pushes it only when all of these hold:
     - `HEAD` is exactly one commit ahead of `origin/main`;
     - that commit's message is `Release <version>`;
     - it changes only `CHANGELOG.md`;
     - its changelog has the version's section.

     Otherwise the script stops and says what it found. Pushing that commit is the only push
     to `main` a resumed release makes.
4. Generates the project and builds Release for Apple silicon (`ARCHS=arm64`), signed with
   the Apple Development identity, with the version settings above.
5. Runs `scripts/verify-app` with the version.
6. Packages `Hulder-<version>.zip` with `ditto -c -k --keepParent`.
7. **Publishing,** unless `--dry-run`, in this order, skipping each step that is already done:
   - tags `HEAD` and pushes the tag;
   - creates the GitHub release, with the version's changelog section as its notes;
   - uploads the zip if the release doesn't have it yet. A published asset is kept, and the
     local build is discarded;
   - downloads the published asset and computes its SHA-256. The cask's checksum always comes
     from that download;
   - clones the tap into a temporary directory, writes `Casks/hulder.rb`, commits
     `hulder <version>` and pushes to the tap's `main`, unless the cask already has this
     version and checksum.

Re-running with `--version` therefore resumes after a failure at any step.

### Homebrew cask

`Casks/hulder.rb` in `michaelrigart/homebrew-tap`:

- `version`, `sha256`, and a `url` pointing at the release asset;
- `name`, a generic `desc` and the repository as `homepage`;
- `depends_on macos:` macOS 27 or later, and `depends_on arch: :arm64`;
- `app "Hulder.app", target: "/Applications/Hulder.app"`: Hulder only works from `/Applications`,
  so the cask ignores another `--appdir`. The builder confirms Homebrew accepts the absolute
  target, and if it doesn't, says so in the caveats instead;
- `uninstall quit: "com.michaelrigart.hulder"`. Quitting restores every hidden item;
- `zap` removes:
  - `~/Library/Application Support/com.michaelrigart.hulder` (state and order backups);
  - `~/Library/Preferences/com.michaelrigart.hulder.plist` (settings and the folder bookmark);
- `livecheck` on the latest GitHub release;
- `caveats` for the first run:
  - "Open Anyway" in System Settings › Privacy & Security, because the app isn't notarized;
  - allowing Hulder under "Device Control and Data Access";
  - picking the menu bar folder in Settings, if reordering is wanted.

On `brew upgrade`, Homebrew carries the "Open Anyway" approval over when the new app satisfies
the old app's designated requirement. A stable team signature does, so upgrades should launch
without it, and the Accessibility grant survives for the same reason.

### Running from the wrong place

Hulder only gets its hiding assertion from `/Applications`, and a copy run from elsewhere (a
download folder, a build folder, another `--appdir`) fails quietly today. At launch, when its
bundle isn't directly in `/Applications`, Hulder says so in its onboarding window ("Move
Hulder to the Applications folder, then open it again") and doesn't try to hide anything.
- **Test:** the check is a pure function of the bundle's path, with tests for `/Applications`,
  a subfolder of it, `~/Applications` and a build folder.

### Design sources

`design/` already holds the designer's SVGs: `app-icon.svg`, `mark.svg`, `mark-on-light.svg`.
`design/render` regenerates the `AppIcon` PNGs in `Hulder/Assets.xcassets` from `app-icon.svg`.
It needs `rsvg-convert` (Homebrew `librsvg`), checks for it, and says so if it is missing.

The menu bar mark's PNGs came from the logo set without an SVG source, so they stay as
delivered and `design/render` doesn't touch them. The committed PNGs are the source of truth
for builds.

### Documentation

- **README** (Hulder has none yet; the repository is public):
  - what Hulder does, and that it needs macOS 27;
  - the Homebrew install, with its first-run steps;
  - building from source, with the ad-hoc signing override;
  - the macOS 27 limits users would otherwise report as bugs, taken from the spec.
- **AGENTS.md:**
  - the release command, the verify script and the render script;
  - that CI signs ad hoc, and that user-visible changes add a `CHANGELOG.md` entry under
    `Unreleased`;
  - "Builds are ad-hoc signed, so every rebuild needs Accessibility granted again" becomes the
    Personal Team note, keeping the ad-hoc case for builds without the certificate.

## Constraints

- Everything in the v1 spec still holds:
  - macOS 27 targets;
  - no entitlements;
  - Hardened Runtime;
  - running from `/Applications`;
  - XcodeGen through mise;
  - HulderCore importing only Foundation and Observation.
- Pushes from Michael's Mac use his existing git and `gh` credentials.

## Prerequisites (Michael)

- The Personal Team's Apple Development certificate and Apple's WWDR G3 intermediate are
  already in his login keychain for Linger. The builder reads the Team ID from the keychain.
- The certificate's subject, the Apple ID's email, is embedded in every public release.
  Michael accepted this for Linger (2026-11-01); the same certificate signs Hulder.

## Delivery

- **Branch:** `feat/hulder-distribution`, from `feat/hulder-v1`, because v1's merge is still
  pending. Its draft pull request targets `main` and is rebased onto `main` once v1 is merged.

## Acceptance

1. CI passes on this work's pull request, with both suites, the Release build and the
   verifier.
2. A Debug and a Release build signed with the Personal Team keep the Accessibility grant
   after a rebuild and reinstall, with no reset. The menu bar folder access and launch at
   login are checked after the switch; any one-time re-grant is recorded in the README.
3. `scripts/release --dry-run` builds, verifies and packages an Apple silicon zip, and prints
   the changelog section it would commit.
4. A Release build run from outside `/Applications` shows the "Move Hulder to the Applications
   folder" message and hides nothing.
5. **After merging,** the first real release creates the tag, the GitHub release with the zip,
   and the cask. Then `brew install --cask michaelrigart/tap/hulder` installs Hulder in
   `/Applications`. After "Open Anyway" and one Accessibility grant, Hulder hides and reorders,
   and Settings shows the version.
6. At the second release, `brew upgrade` launches without "Open Anyway" and keeps the
   Accessibility grant. If Homebrew doesn't carry the approval over, the caveats and the
   README say so instead.

## Left to the builder

- the scripts' language (shell is fine);
- the exact Xcode 27 build selected on the runner, within the rule under CI;
- the pinned action versions;
- the cask's `caveats` wording, and the Homebrew symbol for macOS 27;
- how the verifier detects the probe in the executable, within the constraints above.
