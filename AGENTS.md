# Hulder

Design and behaviour: `docs/superpowers/specs/2026-10-31-hulder-design.md`. Apple's own items:
`docs/superpowers/specs/2026-11-03-hulder-system-items-design.md`, which supersedes v1 on them.
Design-record rules (specs, plans, status, commits) are in the global agent instructions.

## Commands

Run all of these outside any agent sandbox: SwiftPM's nested `sandbox-exec`, the module cache
under `/var/folders` and the Xcode build service fail inside it. Prefix each with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already
points at Xcode.

- Core tests: `swift test --package-path Packages/HulderCore`
- Platform tests: `swift test --package-path Packages/HulderPlatform27`
- Generate the project: `mise exec -- xcodegen generate` (`Hulder.xcodeproj` is not tracked)
- Build: `xcodebuild -project Hulder.xcodeproj -scheme Hulder -configuration Debug -derivedDataPath build -quiet build`
- Release build: the same with `-configuration Release`; `scripts/verify-app` accepts only
  Release builds.
- Without the signing certificate (ad hoc): add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to
  either build.
- Install: `rm -rf /Applications/Hulder.app && ditto build/Build/Products/Debug/Hulder.app /Applications/Hulder.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Hulder.app`
- Script tests: `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` (the
  changelog tool), `scripts/tests/test-release-dry-run` and
  `scripts/tests/test-verify-app <Release Hulder.app> <Debug Hulder.app>`
- Verify a built app: `scripts/verify-app [--team <ID>] <Hulder.app> [<version>]`. It fails on a
  bad signature, non-empty entitlements, `LSUIElement` not true, a wrong bundle identifier or
  version, the probe in the executable, or (with `--team`) a different `TeamIdentifier`.
- Release: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`, on Michael's Mac only (it
  needs the signing certificate and pushes). Use `--dry-run` to check it; never run it for real
  unless Michael asks. `--version` resumes a failed release.
- Regenerate the app icon PNGs from `design/app-icon.svg`: `design/render` (needs `rsvg-convert`)

## Releases and CI

- A user-visible change adds an entry to `CHANGELOG.md` under `## [Unreleased]`, under `Added`,
  `Changed`, `Fixed` or `Removed`. `scripts/release` moves it into the release.
- CI (`.github/workflows/ci.yml`) runs on `xcode-27` and signs ad hoc, because the certificate
  stays on Michael's Mac. It builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, as anyone
  without the certificate does.
- Distribution design: `docs/superpowers/specs/2026-11-03-hulder-distribution-design.md`.

## Rules an agent gets wrong

- `HulderCore` imports only Foundation and Observation. Private API and `#available`
  belong in `HulderPlatform27` only.
- Hulder must run from `/Applications`. macOS 27 only attributes status items to apps there,
  and only a signed bundle can hold an assertion. Launch it with `open`: launched from a
  terminal, macOS gives the Accessibility grant to the terminal.
- Builds are signed with Michael's Personal Team, and the grant survives rebuilds (confirmed
  2026-11-03, along with the menu bar folder access and launch at login). Switching from an ad hoc
  build to a team-signed one needs the grant once. Whether a renewed certificate (yearly) keeps
  the grant is unconfirmed.
  Ad hoc builds (`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, which CI and contributors use) need the
  grant again after every rebuild.
- A bare `log` is a zsh builtin. Use `/usr/bin/log`; the subsystem is
  `com.michaelrigart.hulder`.
- Clean room: never open Thaw's or holzBar's source.

## Probe

A Debug-only probe in `Packages/HulderPlatform27/Sources/HulderPlatform27/Probe/` exercises the platform
types Hulder ships, so a new macOS can be checked by rerunning it. It builds no app composition.

- Launch: `open /Applications/Hulder.app --args -HulderProbe <subcommand> [arguments]`; use `open -n`
  when another probe instance may be running. A panel with a Continue button pauses the steps that
  need a human look.
- Read the log: `/usr/bin/log show --last 10m --style compact --predicate 'subsystem ==
  "com.michaelrigart.hulder" AND category == "probe"'`.
- The `order-*` subcommands write the real menu bar order, after backing it up. Grant access with
  `order-pick` (or in Settings) first.

Subcommands (Accessibility is requested where it is needed):

- `scan`: one read of the bar, each item's owner, key, position and whether macOS manages it, and which owners the extras listing covers.
- `hide <bundleID> [maxSystemItem]`: hide one app through the concealment backend; `maxSystemItem` narrows the system items kept.
- `hide-items <module…>`: hide Apple's modules (`WiFi`, `Battery`, `Clock`, `Sound`, `BentoBox`) through the shipped backend, with every running app allowed, and read which the bar still draws.
- `hide-cancel <bundleID>`: invalidate an assertion right after activating it.
- `relist <bundleID>`: swap to a fresh allowlist after launching another app.
- `swap <a> <b>`: hide `a`, then `b`, while the first is still live.
- `crash <bundleID>`: hide an app, then `abort()`, to time the recovery.
- `menus`: log menu open and close changes and the tracking state for 120 s.
- `items-watch`: log each scan pass and what changed for 120 s.
- `order-pick`: pick the `com.apple.MenuBar` folder, the same grant Settings makes.
- `order-dump`: the order left to right with each key's value, the pinned keys and the drawn keys.
- `order-watch`: log each change to the order for 120 s.
- `order-move <key> <anchorKey>`: move `key` just left of `anchorKey` through the order controller.
- `order-restore`: restore the newest backup through the order controller.
- `order-stress <key>`: for 20 s, rewrite the order every 50 ms with `key` nudged by 0.001 while you drag another icon, then check the drag survived.
