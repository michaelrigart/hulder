# Hulder

Design and behaviour: `docs/superpowers/specs/2026-10-31-hulder-design.md`.
Design-record rules (specs, plans, status, commits) are in the global agent instructions.

## Commands

Run all of these outside any agent sandbox, with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` as a prefix: SwiftPM's nested
`sandbox-exec`, the module cache under `/var/folders` and the Xcode build service fail
inside the Claude sandbox, and `xcode-select` points at the Command Line Tools.

- Core tests: `swift test --package-path Packages/HulderCore`
- Platform tests: `swift test --package-path Packages/HulderPlatform27`
- Generate the project: `mise exec -- xcodegen generate` (`Hulder.xcodeproj` is not tracked)
- Build: `xcodebuild -project Hulder.xcodeproj -scheme Hulder -configuration Debug -derivedDataPath build -quiet build`
- Install: `rm -rf /Applications/Hulder.app && ditto build/Build/Products/Debug/Hulder.app /Applications/Hulder.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Hulder.app`

## Rules an agent gets wrong

- `HulderCore` imports only Foundation and Observation. Private API and `#available`
  belong in `HulderPlatform27` only.
- Hulder must run from `/Applications`. macOS 27 only attributes status items to apps there,
  and only a signed bundle can hold an assertion. Launch it with `open`: launched from a
  terminal, macOS gives the Accessibility grant to the terminal.
- Builds are ad-hoc signed, so every rebuild needs Accessibility granted again.
- A bare `log` is a zsh builtin. Use `/usr/bin/log`; the subsystem is
  `com.michaelrigart.hulder`.
- Clean room: never open Thaw's or holzBar's source.
