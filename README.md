# Hulder

Hulder is a macOS menu bar app that hides other apps' menu bar items and lets you reorder
them. It sorts the items into three sections (Visible, Hidden and Always Hidden) and puts
its own icon between the hidden and the visible ones. Click the icon to show the Hidden
items, Option-click it to show everything, and click it again to hide them.

## Features

- Three sections, set per app: an app's items all hide together.
- A Layout window to arrange the items: drag an item within a row to reorder it, or to
  another row to change its app's section.
- Hides again after a delay (10 seconds by default, or never), and never while a menu from
  the menu bar is open.
- Two hotkeys, one to toggle and one to reveal everything. Both are unset by default.
- Launches at login (you can turn this off in Settings).
- Quitting or crashing leaves the menu bar fully visible.

## Requirements

- macOS 27 or later, on Apple silicon.
- Hulder must run from `/Applications`. macOS 27 only attributes a status item to its app
  there, and only a signed app bundle can hide anything. From anywhere else, Hulder shows
  "Move Hulder to the Applications folder, then open it again." and hides nothing.
- The Accessibility permission, which System Settings lists as "Device Control and Data
  Access". Without it Hulder cannot tell which app owns an item.
- To reorder items, access to the menu bar's preferences folder. Hulder asks for it once,
  in an open panel, and never asks for Full Disk Access.
- To build: Xcode 27 and [mise](https://mise.jdx.dev) for XcodeGen.

## Install

```sh
brew install --cask michaelrigart/tap/hulder
```

The cask installs Hulder to `/Applications/Hulder.app`, whatever `--appdir` says.

Hulder is signed with a free developer certificate and is not notarized, so macOS blocks
it the first time you open it. After the first install:

1. Open System Settings > Privacy & Security, find the message about Hulder and click
   **Open Anyway**.
2. Allow Hulder under Privacy & Security > Device Control and Data Access.
3. To reorder items, open Hulder's Settings > Permissions, click **Allow reordering…** and
   pick the `com.apple.MenuBar` folder.

Upgrade with `brew upgrade --cask hulder`. Releases are signed with the same certificate,
and macOS ties the Accessibility permission to that certificate, so an upgrade is
expected to need none of these steps again. This has not been confirmed yet; if macOS asks
again, repeat them.

The developer certificate is renewed every year. Whether a renewed certificate keeps the
permission has not been confirmed; if macOS asks again after a renewal, repeat the steps.

If you built Hulder yourself before, quit it and delete every copy first, including the
build in your checkout's `build/`. Then run `tccutil reset Accessibility
com.michaelrigart.hulder`, or remove Hulder from the Accessibility list. A build signed
differently from the Homebrew one has an old entry that stays in the list and can look
switched on while it no longer applies.

## Build and install

To build it yourself, you need the full Xcode. If `xcode-select -p` points at the Command
Line Tools, prefix the `xcodebuild` and `swift` commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The project is set up to sign with the maintainer's certificate, which you won't have.
Add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to `xcodebuild` to sign ad hoc instead. Hiding
works with an ad hoc signature.

```sh
mise trust mise.toml
mise exec -- xcodegen generate
xcodebuild -project Hulder.xcodeproj -scheme Hulder -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 -quiet build
rm -rf /Applications/Hulder.app
ditto build/Build/Products/Release/Hulder.app /Applications/Hulder.app
open /Applications/Hulder.app
```

Remove the old app first: `ditto` merges into an existing bundle and would keep stale
files. Quit Hulder before you replace it, so that `open` starts the new build instead of
bringing the old one forward. Start Hulder with `open` or Finder: launched from a
terminal, macOS gives the Accessibility permission to the terminal.

An ad hoc build is a different app to macOS every time you rebuild it, so you need to give
the Accessibility permission again, and the old build's entry stays in the list without
working. Run `tccutil reset Accessibility com.michaelrigart.hulder` to clear it, then
allow Hulder again.

Builds made without the override are signed with the maintainer's certificate and keep the
permission across rebuilds. That is expected from how macOS ties the permission to the
signature, and has not been confirmed yet.

A build made without a version shows `dev` as its version.

## Tests

```sh
swift test --package-path Packages/HulderCore
swift test --package-path Packages/HulderPlatform27
/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

## Probe

A Debug build includes a probe that exercises the platform code Hulder ships, so a new
macOS can be checked by rerunning it. Release builds do not contain it: `scripts/verify-app`
fails a build that does. Build Debug, install it to `/Applications`, then run for example:

```sh
xcodebuild -project Hulder.xcodeproj -scheme Hulder -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 -quiet build
rm -rf /Applications/Hulder.app
ditto build/Build/Products/Debug/Hulder.app /Applications/Hulder.app
open /Applications/Hulder.app --args -HulderProbe scan
```

`AGENTS.md` lists the subcommands. Some of them write the real menu bar order, after
backing it up.

## Releasing

The maintainer cuts a release with `scripts/release`. It needs the signing certificate,
so it runs on the maintainer's Mac, not in CI. It sets the version (the time it starts,
`YYYYMMDD-HHMM`), moves the `Unreleased` entries of `CHANGELOG.md` into that version,
builds, signs, runs `scripts/verify-app`, packages `Hulder-<version>.zip`, tags, publishes
the GitHub release and updates the cask. `scripts/release --dry-run` does everything up to
the package and prints the changelog section; `--version <version>` resumes a release that
failed part way. `design/render` regenerates the app icon from `design/app-icon.svg` and
needs `rsvg-convert` (Homebrew `librsvg`).

## Limitations

These come from macOS 27, not from Hulder. The v1 design records which were measured on
macOS 27.2 and which were reported for 27.0 and not measured again.

- **macOS hides more than you asked it to while an app is in Hidden or Always Hidden.**
  Hiding works by telling macOS which apps may draw on the menu bar, and macOS applies that
  to its own items too. This lasts for as long as any app you put in Hidden or Always
  Hidden is running, including while you have shown the Hidden items with a click. The
  capture indicator button (camera, microphone and screen sharing) is not drawn, and Focus
  is hidden (both measured on 27.2). On 27.0, macOS also hid AirDrop, Now Playing, Fast
  User Switching and Live Activities, and removed controls pinned from Control Center.
  Option-click and the reveal-all hotkey show everything, and quitting Hulder brings them
  back too. The small privacy dot beside the clock stays either way.
- **Items from a process without a bundle identifier can't be hidden.** They stay visible
  whenever hiding is on. Layout lists them read-only, with that reason.
- **The clock and Control Center are pinned.** They stay at the right end of the bar and
  can't be moved or hidden. Layout lists Apple's items as managed by macOS. On 27.0,
  Time Machine and the Input menu were also reported never to hide, and Game Mode could not
  be hidden; none of the three has been confirmed on 27.2.
- **Hiding is per app.** All of an app's items go to the same section.
- **A new app's item can take a while to show.** macOS gives no signal when a newly
  launched app's item appears, so Hulder looks again 1, 3, 10 and 30 seconds after an app
  launches or quits.
- **Items that macOS folds away.** On a crowded bar with a notch, macOS 27 folds items
  that don't fit behind its own « button. macOS decides what folds, and Hulder cannot
  unfold them.
- **If an app's menus can't be watched,** Hulder doesn't hide again on its own while that
  app has an item on the bar. It still hides on a click, a hotkey, locking the screen or
  sleep, and Settings says why.

## Design

- [Hulder v1](docs/superpowers/specs/2026-10-31-hulder-design.md): what macOS 27 allows, what
  was measured on macOS 27.2, and how Hulder works.
- [Distribution](docs/superpowers/specs/2026-11-03-hulder-distribution-design.md):
  signing, releases, the Homebrew cask and CI.
