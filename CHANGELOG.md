# Changelog

All notable changes to Hulder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are release times,
`YYYYMMDD-HHMM` in the maintainer's local time: a version says when a release was made, not
whether it is compatible with the one before. Each section says what changed.

## [Unreleased]

### Added

- Hulder v1: hide other apps' menu bar items in three sections, and reorder them around Hulder's
  icon.
- A Layout window to arrange the menu bar items, and a Settings window to adjust Hulder.
- Install with Homebrew: `brew install --cask michaelrigart/tap/hulder`.
- Releases are signed with a stable certificate, so the Accessibility permission you give Hulder
  survives updates. Switching from a self-built ad hoc copy needs it once more.
- Hulder tells you to move it to `/Applications` when it runs from anywhere else.
- Hide and reorder some of Apple's own menu bar items as you do an app's: Battery, Wi-Fi, Clock,
  Sound, Control Center, Siri and the Input menu. The clock and Control Center can be hidden, but
  macOS keeps them at the right end.

[Unreleased]: https://github.com/michaelrigart/hulder/commits/main
