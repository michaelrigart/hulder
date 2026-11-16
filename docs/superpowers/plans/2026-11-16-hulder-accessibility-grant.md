# Hulder Accessibility grant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented ([PR #7](https://github.com/michaelrigart/hulder/pull/7)). Completed: every
task ran on 2026-11-16; do not run this plan again.
**Goal:** Hulder notices the Accessibility switch within about 2 s while it runs, and relaunches itself to use a grant it did not start with.
**Architecture:** A platform type checks the grant by running a short-lived copy of Hulder on each system notification and shares the result; a pure `GrantRule` in HulderCore decides per reading to use it or relaunch; `AppComposition` executes the rule and tells the platform which value its listing, menu tracking and capabilities use.
**Tech Stack:** Swift 6.4, SwiftPM packages `HulderCore` and `HulderPlatform27`, Swift Testing, AppKit, `/bin/sh`.
**Spec:** `docs/superpowers/specs/2026-11-16-hulder-accessibility-grant-design.md`

## Global Constraints

- `HulderCore` imports only Foundation and Observation. `#available`, ApplicationServices and private API go in `HulderPlatform27`.
- `AppComposition` holds no rules: it connects platform streams to HulderCore types and executes their actions.
- No blocking call on the main actor; every wait for a child process is bounded.
- The check argument is exactly `-HulderCheckAccessibility`; exit 0 is granted, 1 is not.
- Check timing: at once, then 0.5 s and 2 s after each `com.apple.accessibility.api` notification; child timeout 1 s; 0.5 s after terminate, then SIGKILL; at most 0.5 s more after the kill.
- Relaunch timing (`RelaunchHelper.Timing.standard`): poll 0.1 s, 100 drop polls, 50 confirm polls, 10 stable polls, 5 attempts. Logger tag `Hulder`; step variable `HULDER_RELAUNCH_STEP`.
- Log lines (category `app`, notice, `privacy: .public`): `Accessibility: granted=<true|false>`, `Accessibility granted to a running Hulder, relaunching`, `Relaunching Hulder`, `Could not start the relaunch; Hulder keeps running`.
- Commands run outside any agent sandbox, prefixed `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (this Mac's `xcode-select -p` is the Command Line Tools). Core: `swift test --package-path Packages/HulderCore`; platform: `swift test --package-path Packages/HulderPlatform27`.
- The two packages share one checkout: platform tasks build the same target, so run them one at a time. A core task may run beside one platform task.
- Ports read Tafl only through `git -C /Users/michael/Code/tafl show feat/tafl-v1:<path>`; never write there.
- Implementers run the suites for what they changed, never the full suite, and do not commit; the controller commits.

## Review Focus

1. A grant reading that arrives before `AppComposition` subscribes: the subscriber still gets it, as the current value first (Task 3 test `aLateSubscriberStartsAtTheCurrentValue`).
2. Hulder's bundle replaced on disk while it runs (a reinstall): the child cannot start, the check answers nil and the fallback applies (Task 2 `aMissingExecutableIsNil`, Task 4 `aFailedCheckAnswersWithTheFallback`).
3. On, then off, within 2 s in a process that ran without the grant: the first reading relaunches, and every later reading in the old copy does nothing (Task 1 `everyReadingWhileARelaunchIsUnderWayDoesNothing`).
4. Reopen Hulder clicked twice, or clicked while an automatic relaunch is starting: one helper only (Task 7 step: `Relaunch.perform()` returns true without a second helper; checked by reading, since the app target has no tests).
5. A revocation while the welcome window is open in a run that never had the grant: the reading repeats the value in use and changes nothing (Task 1 `aRepeatedReadingDoesNothing`).

---

### Task 1: GrantRule

**Depends on:** none

**Files:**
- Create: `Packages/HulderCore/Sources/HulderCore/Engine/GrantRule.swift`
- Test: `Packages/HulderCore/Tests/HulderCoreTests/GrantRuleTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct GrantRule: Equatable, Sendable {
      public enum Action: Equatable, Sendable { case use(Bool), relaunch, nothing }
      public init()
      public mutating func read(granted: Bool) -> Action
      public mutating func relaunchAttempted(started: Bool) -> Action
  }
  ```

- [ ] **Step 1: Write the failing tests** (Swift Testing, `@testable import HulderCore`). Each is one `var rule = GrantRule()` and the expectations:
  - `aStartWithTheGrantUsesIt`: `read(granted: true) == .use(true)`.
  - `aStartWithoutTheGrantUsesNotGranted`: `read(granted: false) == .use(false)`.
  - `aRepeatedReadingDoesNothing`: after `read(true)`, `read(true) == .nothing`; on a new rule after `read(false)`, `read(false) == .nothing`.
  - `theFirstGrantInAProcessThatRanWithoutItRelaunches`: `read(false)`, then `read(true) == .relaunch`.
  - `aRevocationThenAGrantRelaunches`: `read(true)`; `read(false) == .use(false)`; `read(true) == .relaunch`.
  - `everyReadingWhileARelaunchIsUnderWayDoesNothing`: `read(false)`, `read(true)`; then `read(true)`, `read(false)`, `relaunchAttempted(started: true)` and `read(true)` all `== .nothing`.
  - `aRelaunchThatCouldNotStartUsesTheGrantHere`: `read(false)`, `read(true)`; `relaunchAttempted(started: false) == .use(true)`.
  - `aFailedRelaunchIsNeverTriedAgain`: after the above, `read(false) == .use(false)`, then `read(true) == .use(true)`.
  - `aRelaunchResultWithNoRelaunchDoesNothing`: on a new rule after `read(true)`, `relaunchAttempted(started: false) == .nothing`.
- [ ] **Step 2: Run** the core suite; expect a compile failure naming `GrantRule`.
- [ ] **Step 3: Implement.** State: the value in use (`Bool?`, nil before the first reading), whether the process ran without the grant, whether a relaunch is under way, whether one failed. A reading while relaunching returns `.nothing`. "Not granted" marks the process as having run without the grant. "Granted" in a process that ran without it, with no failed relaunch, sets relaunching and returns `.relaunch`; otherwise it clears "ran without" and uses `true`. Using a value returns `.use(v)` only when it differs from the value in use, else `.nothing`. `relaunchAttempted` does nothing unless a relaunch is under way; `started: false` clears relaunching, marks the relaunch failed, clears "ran without" and uses `true`. Doc comment: why a grant that arrives in a process that ran without it needs a fresh process (spec, "The rule").
- [ ] **Step 4: Run** the core suite; expect all pass.
- [ ] **Step 5: Commit** `Decide what each Accessibility reading does in a tested rule`.

### Task 2: ChildExitStatus

**Depends on:** none

**Files:**
- Create: `Packages/HulderPlatform27/Sources/HulderPlatform27/Apps/ChildExitStatus.swift`
- Test: `Packages/HulderPlatform27/Tests/HulderPlatform27Tests/ChildExitStatusTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ChildExitStatus: Sendable {
      init(executable: URL, arguments: [String], timeout: TimeInterval,
           kill: @escaping @Sendable (pid_t) -> Void = { Darwin.kill($0, SIGKILL) })
      /// 0 is true, 1 is false; anything else, a failed start or no exit within the bounds is nil.
      func run() async -> Bool?
  }
  ```

Port Tafl's `Packages/TaflPlatform27/Sources/TaflPlatform27/Settings/ChildExitStatus.swift` and its tests (`Packages/TaflPlatform27/Tests/TaflPlatform27Tests/ChildExitStatusTests.swift`), replacing Tafl's test support with plain `async` code and `.timeLimit(.minutes(1))`.

- [ ] **Step 1: Write the failing tests:** `exitStatusZeroIsTrue` (`/usr/bin/true`), `exitStatusOneIsFalse` (`/usr/bin/false`), `anyOtherExitStatusIsNil` (`/bin/sh -c 'exit 2'`), `aChildKilledBySignalOneIsNotAnExitStatusOne`, `aMissingExecutableIsNil`, `aChildThatDoesNotExitInTimeIsNilAndTerminated`, `aChildThatIgnoresTerminateIsKilledSoonAfterTheTimeout` (as Tafl's), and new `theAnswerIsBoundedWhenTheKillDoesNotLand`: a child `/bin/sh -c 'trap "" TERM; sleep 5'`, `timeout: 0.2`, `kill: { _ in }`; `run()` returns nil in under 1.5 s (measured with `ContinuousClock`), and the test then kills the child itself.
- [ ] **Step 2: Run** the platform suite; expect a compile failure naming `ChildExitStatus`.
- [ ] **Step 3: Implement** as Tafl's, waiting on a global queue, except: after calling `kill`, wait at most 0.5 s more for the termination handler, and return nil whether or not it fired.
- [ ] **Step 4: Run** the platform suite; expect all pass.
- [ ] **Step 5: Commit** `Read a child process's exit status as a bounded yes or no`.

### Task 3: SharedValue

**Depends on:** none

**Files:**
- Create: `Packages/HulderPlatform27/Sources/HulderPlatform27/Support/SharedValue.swift`
- Test: `Packages/HulderPlatform27/Tests/HulderPlatform27Tests/SharedValueTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// One value shared with any number of subscribers: each gets the current value first, if there is one, then each change.
  final class SharedValue<Value: Sendable & Equatable>: Sendable {
      init(_ initial: Value?)
      var current: Value? { get }
      /// Stores `value`; when it differs from the current one, yields it to every subscriber and returns true.
      @discardableResult func set(_ value: Value) -> Bool
      func values() -> AsyncStream<Value>
      /// Ends every stream; later subscribers get a stream that has ended.
      func finish()
  }
  ```

- [ ] **Step 1: Write the failing tests:** `subscribersGetTheCurrentValueThenEachChange` (two subscribers each read `[false, true]` after `init(false)`, `set(true)`); `anEqualValueIsNotYielded` (`set(false)` on `init(false)` returns false; the next value read after `set(true)` is `true`); `nothingIsYieldedBeforeTheFirstValue` (`init(nil)`, then `set(true)`: the first value read is `true`); `aLateSubscriberStartsAtTheCurrentValue` (`init(false)`, `set(true)`, then subscribe: first value `true`); `finishEndsEveryStream` (a subscriber's iteration ends after `finish()`, and `values()` after `finish()` ends at once); `aCancelledSubscriberIsDropped` (cancel a consuming task, then `set` still reaches a second subscriber).
- [ ] **Step 2: Run** the platform suite; expect a compile failure naming `SharedValue`.
- [ ] **Step 3: Implement** with `OSAllocatedUnfairLock` holding the value, a finished flag and the continuations by id. Register a subscriber and yield its current value under the lock, and yield each change under the lock, so no subscriber misses or repeats a change. `onTermination` removes the continuation.
- [ ] **Step 4: Run** the platform suite; expect all pass.
- [ ] **Step 5: Commit** `Share one value with every subscriber, current value first`.

### Task 4: AccessibilityGrant27

**Depends on:** Task 2 (`ChildExitStatus`), Task 3 (`SharedValue`)

**Files:**
- Create: `Packages/HulderPlatform27/Sources/HulderPlatform27/Apps/AccessibilityGrant27.swift`
- Test: `Packages/HulderPlatform27/Tests/HulderPlatform27Tests/AccessibilityGrant27Tests.swift`

**Interfaces:**
- Consumes: `ChildExitStatus(executable:arguments:timeout:)`, `SharedValue<Bool>`.
- Produces:
  ```swift
  public enum AccessibilityCheck {
      /// The argument that makes a Hulder process answer the check with its exit status and nothing else.
      public static let argument = "-HulderCheckAccessibility"
  }

  final class AccessibilityGrant27: Sendable {
      static let laterChecks: [Duration] = [.milliseconds(500), .seconds(2)]
      convenience init()
      init(center: NotificationCenter, name: Notification.Name, initial: @Sendable () -> Bool,
           check: @escaping @Sendable () async -> Bool?, fallback: @escaping @Sendable () -> Bool,
           after: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void)
      /// The grant as last checked. Reading it never runs a check.
      var isGranted: Bool { get }
      /// The held value first, then each change.
      func values() -> AsyncStream<Bool>
  }
  ```

Port Tafl's `Permission27` (`Packages/TaflPlatform27/Sources/TaflPlatform27/Settings/Permission27.swift`) and its tests (`.../Tests/TaflPlatform27Tests/Permission27Tests.swift`), with the held value in a `SharedValue<Bool>` instead of Tafl's single `changes` stream. The convenience init uses `DistributedNotificationCenter.default()`, `com.apple.accessibility.api`, `AXIsProcessTrusted()` for `initial` and `fallback`, `ChildExitStatus(executable: Bundle.main.executableURL, arguments: [AccessibilityCheck.argument], timeout: 1)` (nil check when there is no executable URL), and a main-queue `asyncAfter` for `after`. Test helpers (a scripted check, a gate that holds one check, a recorder of scheduled delays) go in the test file or `Tests/HulderPlatform27Tests/Support/`.

- [ ] **Step 1: Write the failing tests:** `theInitialValueIsWhatTheInitialReadAnswers`; `readingTheValueNeverRunsTheCheck`; `aNotificationChecksAtOnceAndAtHalfASecondAndTwoSeconds` (scheduled delays `== [.milliseconds(500), .seconds(2)]`, three checks after running them); `aChangedResultIsEmittedOnceAndBecomesTheValue`; `resultsApplyInCheckOrderEvenWhenAnEarlierCheckIsSlow`; `requestsDuringACheckLeadToExactlyOneMoreCheck`; `aFailedCheckAnswersWithTheFallback`; `aCheckThatAnswersIsNotReplacedByTheFallback`; `everySubscriberGetsTheCurrentValueThenEachChange`; `theStreamsEndWhenTheGrantObjectGoes`.
- [ ] **Step 2: Run** the platform suite; expect a compile failure naming `AccessibilityGrant27`.
- [ ] **Step 3: Implement** as Tafl's `Permission27`: checks drain a `bufferingNewest(1)` request stream one at a time; `check() ?? fallback()`; `shared.set(result)`. `deinit` removes the observer, finishes the requests and finishes the shared value. Doc comment carries the measured reason (spec, "What Tafl measured").
- [ ] **Step 4: Run** the platform suite; expect all pass.
- [ ] **Step 5: Commit** `Check the Accessibility grant in a short-lived copy of Hulder`.

### Task 5: RelaunchHelper

**Depends on:** Task 2 (`ChildExitStatus`, which the tests use to run the script)

**Files:**
- Create: `Packages/HulderPlatform27/Sources/HulderPlatform27/Apps/RelaunchHelper.swift`
- Test: `Packages/HulderPlatform27/Tests/HulderPlatform27Tests/RelaunchHelperTests.swift`

**Interfaces:**
- Consumes (tests only): `ChildExitStatus(executable:arguments:timeout:).run()`.
- Produces (public, as Tafl's):
  ```swift
  public struct RelaunchHelper: Sendable {
      public struct Timing: Sendable { /* pollInterval, dropPolls, confirmPolls, stablePolls, attempts */ public static let standard: Timing }
      public init(open: String = "/usr/bin/open", lsappinfo: String = "/usr/bin/lsappinfo",
                  logger: String = "/usr/bin/logger", timing: Timing = .standard)
      public func invocation(oldPID: Int32, bundlePath: String, bundleID: String) -> (executable: URL, arguments: [String])
  }
  ```

Port Tafl's `Packages/TaflPlatform27/Sources/TaflPlatform27/Settings/RelaunchHelper.swift` and `.../Tests/TaflPlatform27Tests/RelaunchHelperTests.swift` (the real script against fake `open`, `lsappinfo` and `logger`), renaming `TAFL_RELAUNCH_STEP` to `HULDER_RELAUNCH_STEP`, `-t Tafl` to `-t Hulder` and every Tafl mention in comments to Hulder. The script and its behaviour are otherwise unchanged. Hulder has no `TaflTestSupport`: replace what the tests take from it with plain `async` code in the test file and `.timeLimit(.minutes(1))`.

- [ ] **Step 1: Write the failing tests** (all of Tafl's): `aStaleListingThatClearsLetsOneOpenStartTheNewCopy`, `anOpenThatFailsOnceIsRepeatedUntilACopyIsRunning`, `anOpenThatNeverStartsACopyGivesUpAfterTheAttemptLimit` (asserts the logger got `-t Hulder` and the give-up line), `aRelaunchThatSucceedsLogsNothing`, `aNewCopyThatExitsBeforeItIsStableIsNotConfirmedAndOpenIsSentAgain`, `aCopyListedAtOnePollWhenARetryBeginsIsNotConfirmed`, `aCopyAlreadyRunningThatStaysIsConfirmedWithoutAnOpen`, `aListingOfTheOldCopyAloneIsNotANewCopy`, `nothingIsOpenedWhileTheOldProcessIsStillRunning`.
- [ ] **Step 2: Run** the platform suite; expect a compile failure naming `RelaunchHelper`.
- [ ] **Step 3: Implement** the port.
- [ ] **Step 4: Run** the platform suite; expect all pass.
- [ ] **Step 5: Commit** `Add the helper that relaunches Hulder once the old copy has gone`.

### Task 6: The platform uses the grant the app says to use

**Depends on:** Task 3 (`SharedValue`), Task 4 (`AccessibilityGrant27`, `AccessibilityCheck`)

**Files:**
- Modify: `Packages/HulderCore/Sources/HulderCore/Platform/MenuBarPlatform.swift` (protocol)
- Modify: `Packages/HulderPlatform27/Sources/HulderPlatform27/Platform27.swift`
- Modify: `Packages/HulderPlatform27/Sources/HulderPlatform27/UnsupportedPlatform.swift`
- Modify: `Packages/HulderPlatform27/Sources/HulderPlatform27/Probe/PlatformProbe27.swift` (`requireAccessibility`, its callers in `run`)
- Delete: `Packages/HulderPlatform27/Sources/HulderPlatform27/Apps/AccessibilityTrust27.swift`

**Interfaces:**
- Consumes: `AccessibilityGrant27`, `SharedValue<Bool>`.
- Produces, on `MenuBarPlatform`:
  ```swift
  /// The Accessibility grant as checked by a fresh process: the current value first, then each change.
  func accessibilityGrant() -> AsyncStream<Bool>
  /// The grant this process uses. Listing, menu tracking and the `listing` capability follow it, not the
  /// checked grant, so a grant waiting for a relaunch starts nothing here. Until the first call,
  /// `capabilityChanges()` emits nothing.
  func useAccessibility(_ granted: Bool)
  ```

- [ ] **Step 1: Platform27.** Replace `trust` with `grant = AccessibilityGrant27()` and `used = SharedValue<Bool>(nil)`. The scanner's and the tracker's `trust:` closures and `capabilityChanges()` read `used.values()`. `accessibilityGrant()` returns `grant.values()`; `useAccessibility(_:)` calls `used.set(_:)`. Update the `MenuBarPlatform` doc comment's list of state streams to include `accessibilityGrant`.
- [ ] **Step 2: UnsupportedPlatform.** `accessibilityGrant()` returns a stream that finishes at once with no element; `useAccessibility(_:)` does nothing.
- [ ] **Step 3: Probe.** `requireAccessibility() async -> Bool` reads `first(of: platform.accessibilityGrant())`. Granted: `note("accessibility: granted")`, `platform.useAccessibility(true)`, return true. Missing: prompt with `AXIsProcessTrustedWithOptions` as today, `panel.wait("Hulder is not trusted for Accessibility yet. Grant it in System Settings > Privacy & Security > Device Control and Data Access, then run the probe again.")`, `note("accessibility: missing; run the probe again after granting it")`, return false. Each caller in `run` skips its subcommand when it returns false (`guard await requireAccessibility() else { break }`). Remove `isTrusted()`.
- [ ] **Step 4: Delete** `AccessibilityTrust27.swift`; `rg -n "AccessibilityTrust27|trust\.values" Packages` returns nothing.
- [ ] **Step 5: Run** the core and platform suites; expect all pass (no test builds `Platform27`; this proves the protocol, the deletion and the probe compile).
- [ ] **Step 6: Commit** `Have the platform use only the grant the app says to use`.

### Task 7: The app relaunches on a new grant, and the docs say so

**Depends on:** Task 1 (`GrantRule`), Task 4 (`AccessibilityCheck.argument`), Task 5 (`RelaunchHelper`), Task 6 (`accessibilityGrant()`, `useAccessibility(_:)`)

**Files:**
- Modify: `Hulder/HulderApp.swift` (`main()`)
- Create: `Hulder/Relaunch.swift`
- Modify: `Hulder/AppComposition.swift`
- Modify: `Hulder/Windows/OnboardingView.swift`
- Modify: `README.md`, `AGENTS.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: Tasks 1, 4, 5, 6 as named.
- Produces: `enum Relaunch { @discardableResult static func perform() -> Bool }`.

- [ ] **Step 1: The check.** First thing in `HulderApp.main()`: `if CommandLine.arguments.contains(AccessibilityCheck.argument) { exit(AXIsProcessTrusted() ? 0 : 1) }`.
- [ ] **Step 2: Relaunch.** Port Tafl's `Tafl/System/Relaunch.swift`: one helper per process (a later call returns true and starts none), `RelaunchHelper().invocation(oldPID:bundlePath:bundleID:)` with `Bundle.main.bundleIdentifier ?? HulderCore.bundleID`, standard streams to the null device, the quit as `RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }`, and the log lines from the Global Constraints through `Log.app`.
- [ ] **Step 3: AppComposition.** Add `private var grantRule = GrantRule()` and `subscribe { await self.followGrant() }` in `start()`. `followGrant()` logs `Accessibility: granted=…` for each reading of `platform.accessibilityGrant()` and executes `grantRule.read(granted:)`. Executing: `.use(let granted)` → `platform.useAccessibility(granted)`; `.relaunch` → log `Accessibility granted to a running Hulder, relaunching`, then execute `grantRule.relaunchAttempted(started: Relaunch.perform())`; `.nothing` → nothing.
- [ ] **Step 4: Welcome window.** In the non-move branch, after the System Settings line, add the secondary-styled text "Hulder restarts itself once it sees the permission. If this window stays open after you turn Hulder on, Reopen Hulder finishes it." and a third button `Button("Reopen Hulder") { Relaunch.perform() }` after Open System Settings.
- [ ] **Step 5: Docs.**
  - `CHANGELOG.md`, under `## [Unreleased]`, `### Fixed`: "Hulder notices when you turn the Accessibility permission on or off while it runs, within about 2 seconds, and restarts itself to use a new grant."
  - `README.md`: Install step 2 adds that Hulder restarts itself once it sees the permission; the build section's ad hoc paragraph says the same applies after each rebuild's new grant.
  - `AGENTS.md`: the "Builds are signed…" rule gains Tafl's wording adapted to Hulder (the child check `-HulderCheckAccessibility`, notice within about 2 s, the relaunch on a grant Hulder did not start with, Reopen Hulder as the manual fallback, grant it by starting Hulder with `open` and switching it on in Device Control and Data Access). The header's spec list adds `docs/superpowers/specs/2026-11-16-hulder-accessibility-grant-design.md` for the Accessibility grant. The Probe section's "Accessibility is requested where it is needed" adds: without it, the probe asks for it and ends; run it again after granting.
- [ ] **Step 6: Build.** `mise exec -- xcodegen generate`, then the Debug build (`xcodebuild -project Hulder.xcodeproj -scheme Hulder -configuration Debug -derivedDataPath build/dd.noindex -quiet build`) and the Release build ad hoc (`-configuration Release CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`); expect both to succeed. `scripts/verify-app build/dd.noindex/Build/Products/Release/Hulder.app` passes.
- [ ] **Step 7: Commit** `Relaunch Hulder when it is granted Accessibility while running`.

## After the last task (controller)

- Full suites: core, platform, `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, `scripts/tests/test-release-dry-run`, and `scripts/tests/test-verify-app <Release Hulder.app> <Debug Hulder.app>`.
- Live checks 1–3 from the spec go to Michael with the commands (team-signed Debug build, installed after Hulder quits).
