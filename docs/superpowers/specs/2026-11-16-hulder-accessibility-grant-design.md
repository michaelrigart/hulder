# Hulder: noticing the Accessibility switch while it runs — design

**Date:** 2026-11-16
**Owner:** Michael Rigart
**Status:** Implemented ([PR #7](https://github.com/michaelrigart/hulder/pull/7)). Signed off by
Michael on 2026-11-16.
**Builds on:** `docs/superpowers/specs/2026-10-31-hulder-design.md` (v1, implemented), section
"Permissions and first launch". Everything else in v1 holds.
**Ported from:** Tafl's grant handling (repository `michaelrigart/tafl`, branch `feat/tafl-v1`,
PR michaelrigart/tafl#2; spec `docs/superpowers/specs/2026-11-01-tafl-design.md`, "Permissions
and first launch").

## Why

Michael asked that Hulder pick up the Accessibility grant while it runs, as Tafl v1 does. Today
Hulder can miss the switch in either direction: a user who turns Hulder on in System Settings
can be left with the welcome window open and nothing hidden until they quit and reopen Hulder,
and a revocation can go unnoticed. Success: Hulder notices the switch within about 2 s in both
directions while it runs in the background, and a grant it did not start with leaves it working,
with no "reopen Hulder" needed.

## What Tafl measured (macOS 27.2; inherited, not re-measured)

- A running process's own `AXIsProcessTrusted()` answer is cached: it refills on the system's
  Accessibility notification, but twice kept the old value for good while System Settings was
  still writing the change. `TCCAccessPreflight` read in-process is cached too. A real
  Accessibility call still answers after a revoke, so it is no trust check either.
- A fresh process answers right. An inactive `LSUIElement` app saw the system notification
  17-32 ms after the switch.
- Accessibility work started in the same process right after a grant can fail for every app.
- Rejected in Tafl and not retried here: re-reading `AXIsProcessTrusted()` in-process after a
  delay; `TCCAccessPreflight` in-process; a real Accessibility call as the trust check;
  relaunching to re-check while the onboarding is open; a manual Reopen as the only way; a
  separate helper executable for the check.
- Verified live in Tafl: one copy throughout a relaunch; the grant survives team-signed rebuilds
  (also confirmed for Hulder on 2026-11-03).

## What Hulder does with the grant today

- `AccessibilityTrust27.values()` reads `AXIsProcessTrusted()` in-process once at subscription
  and once on each `com.apple.accessibility.api` notification. That is the cached answer above.
  Each subscriber builds its own stream and observer.
- Its subscribers, all inside `Platform27`:
  - **Listing.** `MenuBarScanner27` scans the bar and observes MenuBarAgent only while trusted;
    on a revocation it emits one unread pass, so the kept inventory is marked stale.
  - **Menu tracking.** `MenuTracker27` attaches an Accessibility observer to each app while
    trusted and detaches them all on a revocation.
  - **Capabilities.** `capabilityChanges()` reports `listing` from the trust value and caps
    `menuTracking` by it.
  - **Probe.** `PlatformProbe27.requireAccessibility()` reads it, prompts, waits for Continue,
    then reads it again in-process (the cached read).
- Reordering does not follow the trust value. Its drawn-keys read uses Accessibility and returns
  nothing without it.
- `PermissionGate` (HulderCore) turns `listing` into the welcome window and into feeding the
  concealment driver: the driver is fed once listing is available and stays fed after a
  revocation; the welcome window shows only while the grant is missing in a run that never had
  it, and never after a revocation. Settings › Permissions shows the grant as Allowed, missing
  or Removed.

## Goals

- Hulder notices a grant and a revocation within about 2 s while it runs, active or not.
- A grant that arrives in a process that ran without it relaunches Hulder; the new copy starts
  with the grant, so the welcome window does not come back and hiding starts.
- A revocation stops listing and menu tracking, as a revocation already does once noticed.
- Never two copies of Hulder after a relaunch. The helper keeps starting a new copy until one is
  confirmed running, within a capped number of attempts; giving up is logged, and leaves no
  copy until Hulder is opened again or the next login starts it.

## Non-goals

- No change to what Hulder does once it knows the state: the gate, the welcome window's rules,
  the driver staying fed after a revocation, and Settings › Permissions keep their behaviour.
- No single-instance hand-over (Tafl's `InstanceOrder`). Hulder has none today.
- No periodic polling with no notification.

## Anti-goals

- A grant used in the process that ran without it while a relaunch could start, which can leave
  Hulder half-working: listing on but observers that failed for every app.
- A relaunch loop.
- A check that blocks the main actor, or a check that never ends and so stops every later check.

## Approaches

1. **Tafl's design, with the platform using the grant only when the app says so (chosen).** The
   platform checks the grant in a fresh process and reports each reading; a pure rule in
   HulderCore decides, per reading, to use the grant here or relaunch; the app executes it and
   tells the platform which value to use. Listing, menu tracking and the capabilities follow the
   used value, so a grant waiting for a relaunch starts nothing in the old process.
2. **Tafl's design, with the platform using every reading at once.** Smaller: the checked value
   feeds the scanner, the tracker and the capabilities directly, and the app relaunches on the
   resulting capability change. Rejected: in the old process the gate would feed the driver,
   so a first grant would hide items, show them again when the old copy quits, and hide them
   once more in the new copy; and the old copy would attach observers that can fail for every
   app and record those failures.
3. **The rule inside the platform, with the relaunch injected into it.** No protocol change, but
   the platform would execute an app-level decision and call back into the app to quit.
   Rejected: `AppComposition` already executes HulderCore's rules (`PermissionGate`,
   `RevealController`); the relaunch belongs with them.

## Design

### The checked grant (`HulderPlatform27`)

A new `AccessibilityGrant27` replaces `AccessibilityTrust27`. One instance per platform holds
the grant as last checked and shares it with every subscriber.

- **First value:** `AXIsProcessTrusted()` read in-process when the instance is made. A fresh
  process answers right.
- **When it checks:** on each `com.apple.accessibility.api` distributed notification, it asks
  for a check at once, and again 0.5 s and 2 s later (the notification can arrive before the
  change takes effect).
- **How it checks:** it runs its own executable with `-HulderCheckAccessibility`, which exits 0
  for granted and 1 for not (`ChildExitStatus`, ported). A child that fails to start, ends any
  other way, or does not exit within 1 s answers nil; one still running at the timeout is
  terminated, and killed 0.5 s later if it has not exited. The wait after the kill is bounded
  too (0.5 s): a child that has not exited by then still answers nil, and the check ends without
  waiting for it, so the next check is never held up. The waits run on a background queue.
- **Order and coalescing:** checks run one at a time in the order asked, so a late answer never
  overwrites a later one; requests that arrive while a check runs coalesce into one more check.
- **Fallback:** a check that answers nil is replaced by the in-process answer, so a revocation
  is not lost when the child cannot run and the process's own answer has caught up. When all
  three checks after a notification fail and the in-process answer is still stale, the stale
  value stands until the next notification; nothing retries on its own (no polling).
- **Readers:** `values()` yields the held value first, then each change. Reading never runs a
  check. The notification observer is removed and the streams end when the instance goes.

`HulderApp.main()` answers `-HulderCheckAccessibility` with
`exit(AXIsProcessTrusted() ? 0 : 1)` before `NSApplication` is created, so the child runs no
AppKit code. The argument does not match `scripts/verify-app`'s probe check (`-HulderProbe`).

### The rule (`HulderCore`)

`GrantRule`, pure and tested, decides what each reading does:

- The first reading uses the value it read.
- A reading of "not granted" uses "not granted", and marks the process as having run without
  the grant.
- A reading of "granted" in a process that ran without it asks for a relaunch, unless a
  relaunch already failed in this process; then it uses the grant here.
- While a relaunch is under way, every reading changes nothing: the new copy reads the grant
  itself.
- `relaunchAttempted(started:)`: a relaunch that started changes nothing; one that could not
  start is never tried again in this process, and the grant is used here (as in Tafl). The
  helper is `/bin/sh` started with `Process`, so this happens only when the system cannot start
  a process at all. Using the grant here may leave observers failing; hiding does not depend on
  them (the driver works from the layout and the running apps), and the status item's Quit
  followed by opening Hulder gives a fresh process.
- An action is returned only when it changes something: reading the value already in use
  returns nothing.

Actions: use granted, use not granted, relaunch, nothing. This is Tafl's `GrantRule` without its
`showOnboarding`, `startEngine` and `restartObserving` actions: in Hulder the welcome window
follows `PermissionGate`, and the scanner and tracker start and stop by following the used
value.

### The platform (`MenuBarPlatform`)

Two additions to the protocol:

- `accessibilityGrant() -> AsyncStream<Bool>`: the checked grant, current value first, then
  each change.
- `useAccessibility(_ granted: Bool)`: the value this process uses. Listing (the scanner),
  menu tracking and the `listing` capability follow it instead of the raw grant. Until the
  first call, the capabilities stream emits nothing, as it waits today for the first trust
  value.

`Platform27` holds the used value in one shared cell whose streams yield the current value
first, then each change; the scanner, the tracker and `capabilityChanges()` subscribe to it
where they subscribe to `trust.values()` today. The cell is its own type, so it is tested
without building `Platform27` (whose initializer starts the real scanner, tracker and backend).
`UnsupportedPlatform`'s grant stream finishes at once with no reading, and it ignores
`useAccessibility`.

### The app

- `AppComposition` follows `accessibilityGrant()`, logs each reading
  (`Accessibility: granted=…`), passes it to its `GrantRule` and executes the action: use →
  `platform.useAccessibility(_:)`; relaunch → `Relaunch.perform()`, then the rule's
  `relaunchAttempted(started:)` and its action.
- `Relaunch` (ported): starts the relaunch helper and quits. One helper per process; a later
  call returns true without starting another. The quit is scheduled on the main run loop, as
  main-actor work, so `applicationShouldTerminate` runs the normal shutdown. If the helper
  cannot start, Hulder logs it and keeps running.
- `RelaunchHelper` (ported to `HulderPlatform27`): the `/bin/sh` script that waits for the old
  pid to exit; waits, by a capped count of polls, for LaunchServices to stop listing the old
  copy; runs `open` on the bundle; and confirms a copy with a live pid other than the old one
  that stays up for the stable polls. Not confirmed, it tries again from the wait, up to 5
  attempts, then logs one line with `logger -t Hulder` and exits 1. Timing as Tafl's: polls
  every 0.1 s, 10 s to drop, 5 s to confirm, 1 s stable. Each `lsappinfo find` carries its step
  in `HULDER_RELAUNCH_STEP` for the tests' fake. The script's commands (`open`, `lsappinfo`) get
  no deadline of their own, and the wait for the old pid has none: a hung LaunchServices command
  or a shutdown that never finishes leaves the helper waiting, with the old copy gone or still
  running as it was. Both are outside what Hulder can repair from a shell script, as in Tafl.
- **Welcome window:** adds "Hulder restarts itself once it sees the permission. If this window
  stays open after you turn Hulder on, Reopen Hulder finishes it." and a **Reopen Hulder**
  button that calls `Relaunch.perform()`: the manual fallback. When the helper cannot start, the
  button logs it and Hulder keeps running, as an automatic relaunch does. Settings › Permissions
  is unchanged.
- **Probe:** `requireAccessibility()` reads the first value of the checked grant and returns
  whether it is there. Present, the probe calls `platform.useAccessibility(true)`, because its
  `scan`, `items-watch` and `menus` subcommands read the platform's scanner and tracker, which
  follow the used value. Missing, it prompts and its panel says to grant it and run the probe
  again; the probe then ends without running the subcommand, because a process's own answer is
  cached and Accessibility work started right after a grant can fail.

### What a relaunch costs in Hulder

- **First grant** (the process never had it): the driver was never fed, so nothing is hidden;
  the new copy hides as at any launch.
- **A grant after a revocation:** the driver stayed fed, so the old copy's shutdown releases the
  assertion and hidden items show until the new copy applies the layout (about the length of a
  launch). Accepted: it is the cost of a fresh process, and it happens only on a switch the user
  just made.
- Launch at login, the order-file bookmark and the stored state are untouched: the new copy is
  an ordinary launch of the same bundle.

### Parts of Tafl's design that do not apply

- Onboarding on a revocation: Hulder never shows its welcome window after a revocation.
- `startEngine` and `restartObserving`: Hulder's scanner and tracker follow the used value.
- Re-reading the grant on `applicationDidBecomeActive`: the held value is pushed to every
  subscriber, so there is nothing to pull.
- The earlier-instance hand-over: Hulder has no single-instance logic, and the helper accepts
  any new copy it finds running.

## Logging

At notice level, subsystem `com.michaelrigart.hulder`, category `app`: each reading
(`Accessibility: granted=true|false`), `Accessibility granted to a running Hulder, relaunching`,
`Relaunching Hulder`, and `Could not start the relaunch; Hulder keeps running`. The helper's
give-up line goes through `logger` with tag `Hulder`.

## Verification

- **Core tests:** `GrantRule`: a start with and without the grant; the first grant after running
  without it relaunches; a revocation then a grant relaunches; every reading while a relaunch is
  under way does nothing; a relaunch that could not start uses the grant here and is never tried
  again after a later revocation and grant; a repeated reading returns nothing.
- **Platform tests** (ported from Tafl's, adapted):
  - `ChildExitStatus`: exit 0, 1, other; a signal; a missing executable; the timeout; a child
    that ignores terminate is killed; the answer arrives within its bound even when the
    termination is not seen (through an injected wait, since a real SIGKILL always lands).
  - `AccessibilityGrant27` against a fake notification center, a fake check and an injected
    delay: the first value; reading never checks; a notification checks at once, at 0.5 s and at
    2 s; results apply in check order; requests during a check coalesce into one more; nil uses
    the fallback; every subscriber gets the current value, then each change.
  - `RelaunchHelper`: the real script with fake `open`, `lsappinfo` and `logger`: nothing opens
    while the old pid runs; a stale listing that clears lets one `open` start the new copy; a
    failed open is repeated; the attempt limit gives up and logs; a copy that exits before it is
    stable is not confirmed; a listing of the old copy alone is not a new copy; a copy already
    running that stays is confirmed without an open.
  - The used-value cell: every subscriber gets the current value first, then each change;
    nothing before the first `useAccessibility`. `Platform27`'s wiring of the cell to the
    scanner, the tracker and the capabilities is checked live (below), since no test builds
    `Platform27`.
- **Full suites and linters** on the final commit; CI builds ad hoc as today.
- **Live checks on Michael's Mac** (he runs `open`, `tccutil` and the switch; the sandbox blocks
  them for the agent), with a team-signed Debug build installed in `/Applications` after Hulder
  quits:
  1. `tccutil reset Accessibility com.michaelrigart.hulder`, then open Hulder: the welcome
     window shows. Turn Hulder on: within about 2 s Hulder relaunches, the welcome window is
     gone, and items hide by the layout. One copy throughout (`pgrep -lx Hulder`, and the log).
  2. Turn Hulder off while it runs in the background: within about 2 s Settings › Permissions
     shows it Removed and the log shows `listing unavailable`.
  3. Turn it on again: Hulder relaunches once and lists items again.

## Documentation

- `README.md`: the install steps and the build section say Hulder notices the switch while it
  runs and restarts itself to use a new grant.
- `AGENTS.md`: the grant rule gets Tafl's wording for Hulder (the child check, the relaunch,
  Reopen Hulder as the manual fallback), and the spec list names this spec.
- `CHANGELOG.md`, `## [Unreleased]` › `Fixed`: Hulder notices the Accessibility permission
  being turned on or off while it runs, and restarts itself to use a new grant.

## Left to the builder

- Type and file names beyond those above, and where the shared value cell lives.
- How tests wait, within Hulder's test support (`WaitUntil`, `ManualClock`).
