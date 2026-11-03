# Hulder Distribution Implementation Plan

**Status:** In progress (branch `feat/hulder-distribution`).

**Execution notes:** batches by `Depends on:` and shared build output — {1, 4, 7}, then 2, then 3, then 5, then 6, then 8 (Tasks 1, 2, 3, 5 and 6 all build into `build/`); Task 9 with Michael.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Hulder the way Linger ships:
- signed with Michael's Personal Team, so the Accessibility grant survives rebuilds;
- versioned `YYYYMMDD-HHMM`;
- verified, released in one command, and installed with Homebrew;
- with CI on `xcode-27`.

**Architecture:**
- Port Linger's scripts (`scripts/*` and `.github/workflows/ci.yml` in the `michaelrigart/linger` repository) with Hulder's names and the differences the spec lists: no entitlements, no probe in Release, macOS 27, the `xcode-27` runner, the cask's absolute target, and recovery of an unpushed release commit.
- One small app change: Hulder refuses to hide when it isn't run from `/Applications`, and says so.

**Tech Stack:** bash, Python 3 (`/usr/bin/python3`, standard library only), GitHub Actions, XcodeGen through mise, Xcode 27, Swift 6.4, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-03-hulder-distribution-design.md`. Read it, then Linger's implemented counterpart (`docs/superpowers/specs/2026-11-01-linger-distribution-design.md` in the `michaelrigart/linger` repository) and its scripts.

## Global Constraints

- **Repository:** this repository, branch `feat/hulder-distribution`. Commit each task on its own, imperative mood, no agent attribution or co-author lines. Never push to `main`; never create a tag, release or cask.
- **Commands:** `swift test`, `xcodebuild`, `xcodegen`, `codesign` with the keychain identity and `security` all run outside the agent sandbox, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **Team ID:** `CX4MWR5579`, Michael's Personal Team, the same as Linger's. It is public. Pick the identity by Team ID, never by the bare name `Apple Development`.
- **Versions:** `MARKETING_VERSION` is `dev` and `CURRENT_PROJECT_VERSION` is `0` outside a release. A release is `YYYYMMDD-HHMM`, with build number `YYYYMMDDHHMM`.
- **Product:** bundle identifier `com.michaelrigart.hulder`, `LSUIElement` true, no entitlements (the entitlements file holds an empty dictionary), Hardened Runtime on, Apple silicon only (`ARCHS=arm64`).
- **Releases:** asset `Hulder-<version>.zip`, cask `Casks/hulder.rb` in `michaelrigart/homebrew-tap`, `app "Hulder.app", target: "/Applications/Hulder.app"`.
- **CI:** `runs-on: xcode-27`; Xcode 27.1 at `/Applications/Xcode_27.1.app`, or the 27.2 release candidate if Hulder fails with 27.1 (say why in the workflow); never change v1 code to suit the compiler.
- **Public repository:** no machine-specific paths, no certificate, key or token.
- **Code:** HulderCore imports only Foundation and Observation.

## Review Focus

1. **A dirty tree, the wrong branch, or `main` behind `origin/main`** → `scripts/release` stops before building and says which check failed. (Task 5's dry-run tests.)
2. **A resumed release whose tag points elsewhere, or whose local commit isn't exactly `Release <version>` changing only `CHANGELOG.md`** → the script stops and names the commit. (Task 5.)
3. **A Release bundle carrying a probe, `get-task-allow`, another bundle identifier or a wrong version** → `verify-app` fails with the reason. (Task 3's tampered-copy tests.)
4. **Hulder launched from `~/Downloads`, `~/Applications` or a build folder** → no hiding, and the onboarding window says to move it. (Task 2.)
5. **A CI runner without Accessibility or a menu bar** → both suites still pass; a test that needs either is fixed, not skipped. (Task 6.)

---

### Task 1: Sign with the Personal Team and version builds

**Depends on:** none

**Files:**
- Modify: `project.yml` (target settings and `info.properties`)

- [ ] **Step 1: Prove manual signing works.** Change `project.yml`'s `settings.base`:
  - `CODE_SIGN_IDENTITY: "Apple Development"`, `DEVELOPMENT_TEAM: CX4MWR5579`, `CODE_SIGN_STYLE: Manual`, keeping the Hardened Runtime settings;
  - `MARKETING_VERSION: dev`, `CURRENT_PROJECT_VERSION: "0"`.

  In `info.properties`, set `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`. Generate the project, then build Debug and Release.

  Expected: both builds succeed with no provisioning profile. If signing fails, STOP and report: the spec forbids falling back to automatic signing.
- [ ] **Step 2: Check the signature.**
  - `codesign -dvvv build/Build/Products/Release/Hulder.app` shows `TeamIdentifier=CX4MWR5579` and an `Apple Development` authority.
  - `codesign -d -r- …` shows a designated requirement naming the certificate and team, not a `cdhash`.
  - `codesign -d --entitlements - …` shows none, or an empty dictionary.
  - `PlistBuddy` shows `CFBundleShortVersionString` `dev` and `CFBundleVersion` `0`.
- [ ] **Step 3: Check the ad-hoc override.** Add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to the Release build; it signs ad hoc.
- [ ] **Step 4: Commit** "Sign with the Personal Team and version builds".

### Task 2: Refuse to hide outside /Applications

**Depends on:** none

**Files:**
- Create: `Packages/HulderCore/Sources/HulderCore/Engine/InstallLocation.swift`
- Modify: `Packages/HulderCore/Sources/HulderCore/Engine/PermissionGate.swift`, `Hulder/AppComposition.swift`, `Hulder/Windows/OnboardingView.swift`
- Test: `Packages/HulderCore/Tests/HulderCoreTests/InstallLocationTests.swift`, `PermissionGateTests.swift`

**Interfaces:**
- Produces:
  - `public enum InstallLocation { public static func isSupported(bundlePath: String) -> Bool }`: true only when the bundle's parent directory, standardized, is exactly `/Applications`.
  - `PermissionGate(installedInApplications:)`, fixed at creation, with `update(_ capabilities: Capabilities)`: when false, `feedsDriver` stays false and a new `showsMoveNotice` is true.

- [ ] **Step 1: Write the failing tests.**
  - `InstallLocationTests`: `/Applications/Hulder.app` → true; `/Applications/Utilities/Hulder.app`, `/Users/x/Applications/Hulder.app`, `/Users/x/Downloads/Hulder.app` and `/Users/x/Code/hulder/build/Build/Products/Release/Hulder.app` → false; `/Applications/../Applications/Hulder.app` → true.
  - `PermissionGateTests`: with `PermissionGate(installedInApplications: false)`, a later grant (listing available) still leaves `feedsDriver` false and `showsMoveNotice` true; with `true`, today's behaviour is unchanged.
- [ ] **Step 2: Run them; they fail** (no such type or parameter).
- [ ] **Step 3: Implement both.** In `AppComposition`, pass `InstallLocation.isSupported(bundlePath: Bundle.main.bundlePath)` to the gate. When `showsMoveNotice` is true, show the onboarding window with the text "Move Hulder to the Applications folder, then open it again." and no grant prompt. Nothing reaches the driver, so nothing is hidden.
- [ ] **Step 4: Run both suites, then build Debug.** All pass.
- [ ] **Step 5: Commit** "Refuse to hide when Hulder isn't in /Applications".

### Task 3: Verify a built app

**Depends on:** Task 1

**Files:**
- Create: `scripts/verify-app`, `scripts/tests/test-verify-app` (both executable)

**Interfaces:**
- Produces: `scripts/verify-app [--team <ID>] <Hulder.app> [<version>]`. It exits 0 when every check passes, and otherwise prints each `FAIL: <reason>` and exits 1. Tasks 5 and 6 call it.

- [ ] **Step 1: Port Linger's `scripts/verify-app` and its test.** Change these checks:
  - bundle identifier `com.michaelrigart.hulder`;
  - entitlements: no entitlements, or an empty dictionary (Linger requires the sandbox key);
  - a new probe check: the executable must not contain `-HulderProbe` or `usage: scan | hide` (`strings` or `grep -a`; the log category word `probe` must not count);
  - with `--team`, the leaf certificate's Team ID equals it.
- [ ] **Step 2: Port `test-verify-app`.** Each tampered copy must fail with its reason:
  - a changed bundle identifier;
  - `LSUIElement` false;
  - a wrong version;
  - an added `get-task-allow` entitlement (re-sign the copy ad hoc with it);
  - a copy of the Debug build, which contains the probe.
- [ ] **Step 3: Run** `scripts/verify-app build/Build/Products/Release/Hulder.app` (passes), then `scripts/tests/test-verify-app build/Build/Products/Release/Hulder.app build/Build/Products/Debug/Hulder.app` (every tamper case fails as expected).
- [ ] **Step 4: Commit** "Verify built apps".

### Task 4: Changelog and its tool

**Depends on:** none

**Files:**
- Create: `CHANGELOG.md`, `scripts/changelog.py`, `scripts/tests/test_changelog.py`

**Interfaces:**
- Produces: `scripts/changelog.py`, with the same subcommands as Linger's, which Task 5 calls: release a version, and print a version's section.

- [ ] **Step 1: Port Linger's `changelog.py` and its tests unchanged,** apart from the repository URL `https://github.com/michaelrigart/hulder`.
- [ ] **Step 2: Write `CHANGELOG.md`** in Linger's format, with the same preamble. `## [Unreleased]` holds:
  - `### Added`: Hulder v1 (hide other apps' menu bar items in three sections, reorder them around Hulder's icon, Layout, Settings), the Homebrew cask, signed releases, and the move notice outside `/Applications`;
  - the link definition for `[Unreleased]`.
- [ ] **Step 3: Run** `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`. Passes.
- [ ] **Step 4: Commit** "Add the changelog and its tool".

### Task 5: Release script and cask template

**Depends on:** Tasks 1, 3, 4

**Files:**
- Create: `scripts/release`, `scripts/hulder.rb.template`, `scripts/tests/test-release-dry-run`

- [ ] **Step 1: Port Linger's `scripts/release` and `test-release-dry-run`** with Hulder's names, project, scheme, asset name and tap path. Add the spec's recovery for an unpushed release commit. With `--version <v>`, when `HEAD` is exactly one commit ahead of `origin/main`, push it only when:
  - its message is `Release <v>`;
  - it changes only `CHANGELOG.md`;
  - the changelog has `## [<v>]`.

  Otherwise stop and say what was found.
- [ ] **Step 2: Write `hulder.rb.template`** from Linger's, with:
  - `app "Hulder.app", target: "/Applications/Hulder.app"`;
  - `depends_on arch: :arm64` and `depends_on macos: ">= :golden_gate"`, Homebrew's symbol for macOS 27 (`MacOSVersion::SYMBOLS` in Homebrew 7.0.12 maps `golden_gate` to 27);
  - `uninstall quit: "com.michaelrigart.hulder"`;
  - `zap trash:` `~/Library/Application Support/com.michaelrigart.hulder` and `~/Library/Preferences/com.michaelrigart.hulder.plist`;
  - `livecheck` as Linger's;
  - `caveats` for "Open Anyway", allowing Hulder under "Device Control and Data Access", and picking the menu bar folder in Settings for reordering.

  Check that the absolute `target:` is valid: `brew style` on a rendered copy, or Homebrew's cask DSL docs. If it isn't, use `app "Hulder.app"` and add a caveat that Hulder must be in `/Applications`.
- [ ] **Step 3: Extend `test-release-dry-run`** with the recovery checks, against a scratch repository:
  - a local `Release <v>` commit changing only `CHANGELOG.md` is accepted;
  - one that also changes another file is refused;
  - one with another message is refused.
- [ ] **Step 4: Commit** "Add the release script and the cask template". The script refuses a dirty tree, even for a dry run, so this comes first.
- [ ] **Step 5: Run** `scripts/tests/test-release-dry-run`, then `scripts/release --dry-run` on this branch, now clean. The dry run must:
  - build, signed with the team;
  - pass `verify-app` with the version;
  - write `Hulder-<version>.zip`;
  - print the changelog section.

  Delete the zip afterwards. A failure is fixed in a follow-up commit, and Step 5 runs again.

### Task 6: CI

**Depends on:** Tasks 3, 4

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Port Linger's `ci.yml`:**
  - `runs-on: xcode-27`, with `sudo xcode-select -s /Applications/Xcode_27.1.app`;
  - the same pinned `actions/checkout` and `jdx/mise-action` SHAs as Linger (check they still exist);
  - steps: changelog tests, `swift test --package-path Packages/HulderCore`, `swift test --package-path Packages/HulderPlatform27`, `mise exec -- xcodegen generate`, the Release build with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64`, `scripts/verify-app` on the product.
  - then a Debug build with the same override, and `scripts/tests/test-verify-app` on the Release and Debug products. The spec requires the verifier's own test in CI, and its probe case needs the Debug build.
- [ ] **Step 2: Check locally** what CI will run: the same commands, with the ad-hoc override. All pass.
- [ ] **Step 3: Commit** "Run CI on the Xcode 27 image". CI itself runs once the pull request exists; the controller watches that run and fixes failures in a new commit.

### Task 7: Render the app icon from its source

**Depends on:** none

**Files:**
- Create: `design/render` (executable)

- [ ] **Step 1: Write `design/render`,** ported from Linger's. It renders only `design/app-icon.svg` into every PNG listed in `Hulder/Assets.xcassets/AppIcon.appiconset/Contents.json`, at its pixel size, with `rsvg-convert`. It checks `rsvg-convert` is installed and says to install Homebrew `librsvg` if not. It doesn't touch `HulderMenuBar.imageset`.
- [ ] **Step 2: Run it into a scratch copy** (an optional output-directory argument), and check each PNG's pixel size matches its slot (`sips -g pixelWidth`). Don't replace the committed PNGs.
- [ ] **Step 3: Commit** "Render the app icon from its source".

### Task 8: README and AGENTS.md

**Depends on:** Tasks 1–7

**Files:**
- Create: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Write `README.md`:**
  - what Hulder does, that it needs macOS 27 on Apple silicon and must run from `/Applications`;
  - the Homebrew install with its first-run steps (the cask's caveats);
  - building from source, with the ad-hoc override, and the probe (Debug only);
  - the macOS 27 limits users would otherwise report as bugs: macOS's side effects while anything is hidden, the items without a bundle identifier, the Clock and Control Center being pinned;
  - a pointer to the specs.
- [ ] **Step 2: Update `AGENTS.md`:**
  - the release command, `verify-app`, `design/render`;
  - CI runs on `xcode-27` and signs ad hoc;
  - user-visible changes add a `CHANGELOG.md` entry under `Unreleased`;
  - replace "Builds are ad-hoc signed, so every rebuild needs Accessibility granted again" with: team-signed builds keep the grant, and ad-hoc builds (the override) need it again. Task 9 confirms this. Until it has run, say so in the README's first-run steps rather than state it as measured.
- [ ] **Step 3: Commit** "Document installing, building and releasing".

### Task 9: Acceptance with Michael: what survives the signing change

**Depends on:** Tasks 1–8. This needs Michael at the Mac, for the Accessibility grant, and runs when he is back. The draft pull request doesn't wait for it, but its description lists it as open.

- [ ] **Step 1:** Install a team-signed Debug build in `/Applications`, launch it with `open`, and grant Accessibility once. Record whether:
  - the menu bar folder needed picking again;
  - launch at login still shows in Login Items.
- [ ] **Step 2:** Rebuild, reinstall (`rm -rf` then `ditto`) and relaunch. The log shows listing available at launch with no new grant, and reordering available. Repeat for a Release build.
- [ ] **Step 3:** Run the dry-run Release product from outside `/Applications`: `open build/Build/Products/Release/Hulder.app` (acceptance 4). Expect the "Move Hulder to the Applications folder, then open it again." window with no grant buttons, and nothing hidden. Quit it, and delete that copy before acceptance 5 (the README's note on removing every copy).
- [ ] **Step 4:** Record the results everywhere the grant behaviour is stated: the README's first-run steps, the grant rule in `AGENTS.md`, `CHANGELOG.md` and the cask caveats in `scripts/hulder.rb.template`. Each says whether a one-time re-grant is needed and whether rebuilds and updates keep the grant, and drops the "not yet confirmed" hedge once it is measured. Then commit "Record what survives the signing change".
