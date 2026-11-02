import Darwin
import Foundation
import HulderCore
import os
import Testing
@testable import HulderPlatform27

/// A stream source for tests: every call to `stream()` is an independent stream that starts with the latest
/// value, if any, and then follows `send`.
private final class Feed<Value: Sendable>: Sendable {
    private struct State {
        var latest: Value?
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func stream() -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { state in
                state.continuations[id] = continuation
                if let latest = state.latest { continuation.yield(latest) }
            }
            continuation.onTermination = { [state] _ in state.withLock { $0.continuations[id] = nil } }
        }
    }

    func send(_ value: Value) {
        state.withLock { state in
            state.latest = value
            state.continuations.values.forEach { $0.yield(value) }
        }
    }
}

/// A stand-in for `ProcessExit27`: `exit(pid)` makes every stream watching that pid yield once and finish. A stream
/// asked for afterwards watches a new process.
private final class ExitSource: Sendable {
    private struct State {
        var subscribers: [pid_t: [UUID: AsyncStream<Void>.Continuation]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let subscriptionContinuation: AsyncStream<pid_t>.Continuation
    /// Yields the pid of every stream asked for, in order.
    let subscriptionLog: AsyncStream<pid_t>

    init() {
        (subscriptionLog, subscriptionContinuation) = AsyncStream<pid_t>.makeStream()
    }

    func exits(of pid: pid_t) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { $0.subscribers[pid, default: [:]][id] = continuation }
            subscriptionContinuation.yield(pid)
            continuation.onTermination = { [state] _ in state.withLock { $0.subscribers[pid]?[id] = nil } }
        }
    }

    func exit(_ pid: pid_t) {
        let watching = state.withLock { Array(($0.subscribers.removeValue(forKey: pid) ?? [:]).values) }
        for continuation in watching {
            continuation.yield()
            continuation.finish()
        }
    }
}

/// A window source whose Accessibility state the test controls. An attach can be held until the test lets it
/// finish, and every observer is tracked by its token.
private final class FakeWindowSource: MenuWindowSource {
    private struct State {
        var granted = false
        var showingMenu: Set<pid_t> = []
        var attachFailuresLeft: [pid_t: Int] = [:]
        var held: [pid_t: DispatchSemaphore] = [:]
        var waiting: [pid_t: DispatchSemaphore] = [:]
        var heldOutcome: [pid_t: Bool] = [:]
        var nextToken: UInt64 = 0
        var live: [MenuObserverToken: pid_t] = [:]
        var issued: [MenuObserverToken] = []
        var attached: [pid_t] = []
        var attachCalls: [pid_t] = []
        var detached: [MenuObserverToken] = []
        var eventsCalls = 0
        var reads: [pid_t] = []
        /// Calls made while the grant was missing.
        var callsWithoutGrant = 0
        var subscribers: [UUID: AsyncStream<pid_t>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readContinuation: AsyncStream<pid_t>.Continuation
    private let enteredContinuation: AsyncStream<pid_t>.Continuation
    private let attemptContinuation: AsyncStream<pid_t>.Continuation
    private let detachContinuation: AsyncStream<MenuObserverToken>.Continuation
    /// Yields the process of every `isOpen` call, in order.
    let readLog: AsyncStream<pid_t>
    /// Yields the process of every `attach` call as it starts.
    let attemptLog: AsyncStream<pid_t>
    /// Yields the process of every held attach as it starts waiting.
    let heldAttachStarted: AsyncStream<pid_t>
    /// Yields each detached token.
    let detachLog: AsyncStream<MenuObserverToken>

    init(showingMenu: Set<pid_t> = [], granted: Bool = false) {
        (readLog, readContinuation) = AsyncStream<pid_t>.makeStream()
        (heldAttachStarted, enteredContinuation) = AsyncStream<pid_t>.makeStream()
        (attemptLog, attemptContinuation) = AsyncStream<pid_t>.makeStream()
        (detachLog, detachContinuation) = AsyncStream<MenuObserverToken>.makeStream()
        state.withLock { $0.showingMenu = showingMenu; $0.granted = granted }
    }

    var attached: [pid_t] { state.withLock { $0.attached } }
    var attachCalls: [pid_t] { state.withLock { $0.attachCalls } }
    var liveObservers: [pid_t] { state.withLock { Array($0.live.values) } }
    var detached: [MenuObserverToken] { state.withLock { $0.detached } }
    /// Every token `attach` has returned.
    var attachedTokens: [MenuObserverToken] { state.withLock { Array($0.issued) } }
    var eventsCalls: Int { state.withLock { $0.eventsCalls } }
    var reads: [pid_t] { state.withLock { $0.reads } }
    var callsWithoutGrant: Int { state.withLock { $0.callsWithoutGrant } }

    func grant() { state.withLock { $0.granted = true } }
    func setShowingMenu(_ pids: Set<pid_t>) { state.withLock { $0.showingMenu = pids } }
    func failNextAttach(_ pid: pid_t) { state.withLock { $0.attachFailuresLeft[pid] = 1 } }
    func failEveryAttach(_ pid: pid_t) { state.withLock { $0.attachFailuresLeft[pid] = Int.max } }
    /// The next attach to `pid` waits in `attach` until `release`.
    func holdNextAttach(_ pid: pid_t) { state.withLock { $0.held[pid] = DispatchSemaphore(value: 0) } }

    func release(_ pid: pid_t, succeeding: Bool) {
        let semaphore = state.withLock { state -> DispatchSemaphore? in
            state.heldOutcome[pid] = succeeding
            return state.waiting[pid]
        }
        semaphore?.signal()
    }

    func send(_ pid: pid_t) {
        state.withLock { state in state.subscribers.values.forEach { $0.yield(pid) } }
    }

    func events() -> AsyncStream<pid_t> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { state in
                state.eventsCalls += 1
                state.subscribers[id] = continuation
            }
            continuation.onTermination = { [state] _ in state.withLock { $0.subscribers[id] = nil } }
        }
    }

    func attach(_ pid: pid_t) -> MenuObserverToken? {
        attemptContinuation.yield(pid)
        let hold = state.withLock { state -> DispatchSemaphore? in
            state.attachCalls.append(pid)
            let hold = state.held.removeValue(forKey: pid)
            if let hold { state.waiting[pid] = hold }
            return hold
        }
        let forcedOutcome: Bool?
        if let hold {
            enteredContinuation.yield(pid)
            hold.wait()
            forcedOutcome = state.withLock { $0.heldOutcome[pid] }
        } else {
            forcedOutcome = nil
        }
        return state.withLock { state in
            guard state.granted else {
                state.callsWithoutGrant += 1
                return nil
            }
            if forcedOutcome != true {
                if forcedOutcome == false { return nil }
                if let left = state.attachFailuresLeft[pid], left > 0 {
                    state.attachFailuresLeft[pid] = left == Int.max ? left : left - 1
                    return nil
                }
            }
            state.nextToken += 1
            let token = MenuObserverToken(rawValue: state.nextToken)
            state.live[token] = pid
            state.issued.append(token)
            state.attached.append(pid)
            return token
        }
    }

    func detach(_ token: MenuObserverToken) {
        state.withLock { state in
            state.live[token] = nil
            state.detached.append(token)
        }
        detachContinuation.yield(token)
    }

    func isOpen(_ pid: pid_t) -> Bool {
        let open = state.withLock { state -> Bool in
            state.reads.append(pid)
            if !state.granted { state.callsWithoutGrant += 1 }
            return state.showingMenu.contains(pid)
        }
        readContinuation.yield(pid)
        return open
    }
}

private struct Harness {
    let source: FakeWindowSource
    let trust = Feed<Bool>()
    let processes = Feed<Set<pid_t>>()
    let launched = Feed<pid_t>()
    let covered = Feed<Set<pid_t>>()
    let exits = ExitSource()
    let tracker: MenuTracker27

    init(showingMenu: Set<pid_t> = [], granted: Bool = false) {
        let source = FakeWindowSource(showingMenu: showingMenu, granted: granted)
        let (trust, processes, launched, covered, exits) = (trust, processes, launched, covered, exits)
        // Every input says its current value first, as the platform's streams do.
        processes.send([])
        covered.send([])
        self.source = source
        tracker = MenuTracker27(
            source: source,
            queue: AXQueue(),
            trust: { trust.stream() },
            processes: { processes.stream() },
            launched: { launched.stream() },
            covered: { covered.stream() },
            exits: { exits.exits(of: $0) }
        )
    }
}

/// The untrusted half is best effort (R34): nothing observable marks "the untrusted state has been handled", so
/// `callsWithoutGrant` can miss a call. An untrusted-phase `attach` or `isOpen` that reaches the fake only after
/// `source.grant()` is not counted, and the test then passes falsely. The grant half is exact.
@Test(.timeLimit(.minutes(1))) func grantAfterDeniedStartAttachesAndReads() async {
    let harness = Harness(showingMenu: [20])
    let (source, tracker) = (harness.source, harness.tracker)
    var open = tracker.values().makeAsyncIterator()

    // Untrusted start: the current value comes first, and nothing is open.
    #expect(await open.next() == false)
    harness.processes.send([10, 20])
    harness.trust.send(false)
    #expect(tracker.tracking == .unavailable)

    // The grant: attach to both apps, read each once, so the open menu counts.
    source.grant()
    harness.trust.send(true)
    #expect(await open.next() == true)
    #expect(tracker.tracking == .full)
    #expect(source.attached.sorted() == [10, 20])
    var reads = source.readLog.makeAsyncIterator()
    #expect(Set([await reads.next(), await reads.next()]) == [10, 20])

    // Close the menu and send one event: only that app is read again.
    source.setShowingMenu([])
    source.send(20)
    #expect(await open.next() == false)
    #expect(source.reads.sorted() == [10, 20, 20])
    // Neither attach nor read ran before the grant, and the first `true` came from the read after it.
    #expect(source.callsWithoutGrant == 0)
}

@Test(.timeLimit(.minutes(1))) func quittingTheOpenAppClosesItsMenu() async {
    let harness = Harness(showingMenu: [20], granted: true)
    var open = harness.tracker.values().makeAsyncIterator()
    #expect(await open.next() == false)
    harness.processes.send([10, 20])
    harness.trust.send(true)
    #expect(await open.next() == true)

    harness.processes.send([10])
    #expect(await open.next() == false)
}

@Test(.timeLimit(.minutes(1))) func losingTheGrantClearsOpenMenusAndTheCapability() async {
    let harness = Harness(showingMenu: [20], granted: true)
    var open = harness.tracker.values().makeAsyncIterator()
    #expect(await open.next() == false)
    harness.processes.send([20])
    harness.trust.send(true)
    #expect(await open.next() == true)

    harness.trust.send(false)
    #expect(await open.next() == false)
    #expect(harness.tracker.tracking == .unavailable)
}

@Test(.timeLimit(.minutes(1))) func trackingChangesFollowAttachment() async {
    let harness = Harness(granted: true)
    var tracking = harness.tracker.trackingChanges().makeAsyncIterator()
    #expect(await tracking.next() == .unavailable)
    harness.processes.send([10])
    harness.trust.send(true)
    #expect(await tracking.next() == .full)
    harness.trust.send(false)
    #expect(await tracking.next() == .unavailable)
}

@Test(.timeLimit(.minutes(1))) func aSecondSessionAfterTheFirstEndsStillSeesEvents() async {
    let harness = Harness(showingMenu: [20], granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    harness.processes.send([20])
    harness.trust.send(true)
    var reads = source.readLog.makeAsyncIterator()

    // The first session sees the menu that is already open, then ends.
    for await open in tracker.values() where open { break }
    _ = await reads.next()

    // The second session starts closed; an event then opens it.
    source.setShowingMenu([])
    var second = tracker.values().makeAsyncIterator()
    #expect(await second.next() == false)
    _ = await reads.next()
    source.setShowingMenu([20])
    source.send(20)
    #expect(await second.next() == true)
}

@Test(.timeLimit(.minutes(1))) func twoConcurrentSessionsBothSeeEvents() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    var first = tracker.values().makeAsyncIterator()
    var second = tracker.values().makeAsyncIterator()
    #expect(await first.next() == false)
    #expect(await second.next() == false)
    var reads = source.readLog.makeAsyncIterator()
    harness.processes.send([20])
    harness.trust.send(true)
    _ = await reads.next()

    source.setShowingMenu([20])
    source.send(20)
    #expect(await first.next() == true)
    #expect(await second.next() == true)
}

@Test(.timeLimit(.minutes(1))) func anAttachThatFailedIsRetriedOnTheNextProcessChange() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    source.failNextAttach(10)
    var tracking = tracker.trackingChanges().makeAsyncIterator()
    _ = await tracking.next()
    harness.processes.send([10])
    harness.trust.send(true)
    #expect(await tracking.next() == .full)
    var reads = source.readLog.makeAsyncIterator()
    _ = await reads.next()
    #expect(source.attached.isEmpty)

    // Another app starts: the failed one is attached too, and read.
    harness.processes.send([10, 30])
    _ = await reads.next()
    _ = await reads.next()
    #expect(source.attached.sorted() == [10, 30])
}

@Test(.timeLimit(.minutes(1))) func anAttachThatFailedIsRetriedWhenTheAppFinishesLaunching() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    source.failNextAttach(10)
    var tracking = tracker.trackingChanges().makeAsyncIterator()
    _ = await tracking.next()
    harness.processes.send([10])
    harness.trust.send(true)
    #expect(await tracking.next() == .full)
    var reads = source.readLog.makeAsyncIterator()
    _ = await reads.next()
    #expect(source.attached.isEmpty)

    // The app finishes launching: it is attached, then read.
    harness.launched.send(10)
    _ = await reads.next()
    #expect(source.attached == [10])
}

@Test(.timeLimit(.minutes(1))) func finishingLaunchingDoesNotAttachAgainWhenAlreadyAttached() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    var open = tracker.values().makeAsyncIterator()
    _ = await open.next()
    harness.processes.send([10])
    harness.trust.send(true)
    var reads = source.readLog.makeAsyncIterator()
    _ = await reads.next()
    harness.launched.send(10)
    harness.launched.send(10)
    source.setShowingMenu([10])
    source.send(10)
    #expect(await open.next() == true)
    #expect(source.attachCalls == [10])
}

private func window(x: Double = 100, top: Double) -> CGRect {
    CGRect(x: x, y: top, width: 300, height: 200)
}

// A notched built-in display on the left (bar 38) and an external one on the right (bar 24), tops aligned.
private let builtIn = ScreenBar(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), barHeight: 38)
private let external = ScreenBar(frame: CGRect(x: 1512, y: 982 - 1440, width: 2560, height: 1440), barHeight: 24)
private let single = ScreenBar(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), barHeight: 24)

@Test func aStandardWindowAtTheBarIsNotAMenu() {
    let edges = BarEdges.edges(for: [single])
    #expect(!WindowRule.isOpen(subrole: "AXStandardWindow", frame: window(top: 24), edges: edges))
}

@Test func aNonStandardWindowAtTheBarIsAMenu() {
    let edges = BarEdges.edges(for: [single])
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(top: 24), edges: edges))
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(top: 25.9), edges: edges))
    #expect(WindowRule.isOpen(subrole: nil, frame: window(top: 24), edges: edges))
}

@Test func aNonStandardWindowBelowTheBarIsNotAMenu() {
    let edges = BarEdges.edges(for: [single])
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(top: 34), edges: edges))
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(top: 24), edges: []))
}

// Catches popovers on a second display being missed: they hang from that display's own bar, whose height differs.
@Test func aPopoverOnEachOfTwoScreensIsAMenuAtItsOwnBarHeight() {
    let edges = BarEdges.edges(for: [builtIn, external])
    #expect(edges.map(\.bottom) == [38, 24])
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 700, top: 38), edges: edges))
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 2000, top: 24), edges: edges))
    // Each screen's bar height applies to its own windows only.
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 700, top: 24), edges: edges))
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 2000, top: 38), edges: edges))
}

@Test func anExternalScreenAboveThePrimaryHasAnEdgeAboveZero() {
    // The external is 98 pt taller than the built-in, with its bottom at the built-in's: its top is 98 pt higher.
    let tall = ScreenBar(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1080), barHeight: 24)
    let edges = BarEdges.edges(for: [builtIn, tall])
    #expect(edges.map(\.bottom) == [38, -74])
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 2000, top: -74), edges: edges))
}

// Catches the old edge, `frame.maxY - visibleFrame.maxY`, which is 0 while the bar auto-hides.
@Test func anAutoHidingBarStillHasItsEdgeBelowTheScreensTop() {
    let edges = BarEdges.edges(for: [single])
    #expect(edges.map(\.bottom) == [24])
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 2000, top: 24), edges: edges))
    #expect(BarEdges.barHeight(reserved: 0, safeAreaTop: 0, statusBarThickness: 24) == 24)
    #expect(BarEdges.barHeight(reserved: 0, safeAreaTop: 38, statusBarThickness: 24) == 38)
}

// Catches a bar height taken from the notch inset or the status bar's thickness while the display says how much
// room it reserves: neither is measured on 27.2, and a 2 pt error would hide every popover on that display.
@Test func aScreenThatReservesRoomForItsBarUsesThatRoom() {
    #expect(BarEdges.barHeight(reserved: 37, safeAreaTop: 38, statusBarThickness: 24) == 37)
    #expect(BarEdges.barHeight(reserved: 25, safeAreaTop: 0, statusBarThickness: 24) == 25)
}

// Catches a window that is on no screen being matched to the nearest one's bar.
@Test func aWindowOutsideEveryScreensXRangeIsNotAMenu() {
    let edges = BarEdges.edges(for: [builtIn, external])
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: 9000, top: 24), edges: edges))
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", frame: window(x: -2000, top: 38), edges: edges))
}

@Test(.timeLimit(.minutes(1))) func aRestartedEnginesObserverSurvivesTheOldEnginesLateAttach() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    source.holdNextAttach(10)
    harness.processes.send([10])
    harness.trust.send(true)

    // The first engine is attaching pid 10 when its last subscriber leaves.
    let first = Task { for await _ in tracker.values() {} }
    var started = source.heldAttachStarted.makeAsyncIterator()
    #expect(await started.next() == 10)
    first.cancel()
    await first.value

    // A new engine attaches pid 10 and reads it.
    var reads = source.readLog.makeAsyncIterator()
    var second = tracker.values().makeAsyncIterator()
    #expect(source.eventsCalls == 2)
    #expect(await second.next() == false)
    #expect(await reads.next() == 10)
    let newToken = source.attached.first
    #expect(source.liveObservers == [10])

    // The old attach finishes now. The old engine lets go of its own observer only.
    source.release(10, succeeding: true)
    var detached = source.detachLog.makeAsyncIterator()
    let oldToken = await detached.next()
    #expect(oldToken != nil)
    #expect(source.liveObservers == [10])
    #expect(source.detached == [oldToken].compactMap { $0 })
    #expect(source.attached.count == 2)
    #expect(newToken != nil)
}

@Test(.timeLimit(.minutes(1))) func aLaunchSignalDuringAnAttachIsRetriedWhenThatAttachFails() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    source.holdNextAttach(10)
    source.failNextAttach(77)
    var attempts = source.attemptLog.makeAsyncIterator()
    var reads = source.readLog.makeAsyncIterator()
    var tracking = tracker.trackingChanges().makeAsyncIterator()
    _ = await tracking.next()
    harness.processes.send([10, 77])
    harness.trust.send(true)
    #expect(Set([await attempts.next(), await attempts.next()]) == [10, 77])

    // Signals are handled in order: 77's retry means 10's signal was already handled, while 10's attach is held.
    harness.launched.send(10)
    harness.launched.send(77)
    #expect(await attempts.next() == 77)
    source.release(10, succeeding: false)
    // Once 10 is attached after the retry, it is read; 77 may be read before that.
    while let pid = await reads.next(), pid != 10 {}
    #expect(source.attachCalls.filter { $0 == 10 }.count == 2)
    #expect(source.liveObservers.sorted() == [10, 77])
}

@Test(.timeLimit(.minutes(1))) func aPermanentlyFailingAppStopsBeingRetriedOnProcessChanges() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    source.failEveryAttach(10)
    var tracking = tracker.trackingChanges().makeAsyncIterator()
    _ = await tracking.next()
    var reads = source.readLog.makeAsyncIterator()
    harness.processes.send([10])
    harness.trust.send(true)
    #expect(await tracking.next() == .full)
    #expect(await reads.next() == 10)

    // Each change reads the app that is new; the failing one is tried at most once more.
    var running: Set<pid_t> = [10]
    for new: pid_t in [30, 40, 50] {
        running.insert(new)
        harness.processes.send(running)
        #expect(await reads.next() == new)
    }
    #expect(source.attachCalls.filter { $0 == 10 }.count == 2)
}

@Test(.timeLimit(.minutes(1))) func aPermanentlyFailingAppGetsOneRetryOnItsLaunchSignal() async {
    let harness = Harness(granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    source.failEveryAttach(10)
    source.failNextAttach(77)
    harness.processes.send([10, 77])
    harness.trust.send(true)
    var reads = source.readLog.makeAsyncIterator()
    var open = tracker.values().makeAsyncIterator()
    _ = await open.next()
    _ = await reads.next()
    _ = await reads.next()

    // Signals are handled in order, so 77's attach and read mean both signals for 10 were handled.
    harness.launched.send(10)
    harness.launched.send(10)
    harness.launched.send(77)
    #expect(await reads.next() == 77)
    #expect(source.attachCalls.filter { $0 == 10 }.count == 2)
    #expect(source.attachCalls.filter { $0 == 77 }.count == 2)
}

@Test func menuTrackingIsUnavailableWhileUntrustedWhateverTheTrackerSays() {
    let capabilities = Platform27.capabilities(hiding: .available, trusted: false, tracking: .full, reordering: .available)
    #expect(capabilities.menuTracking == .unavailable)
    #expect(capabilities.listing == .unavailable(Platform27.accessibilityMissing))
    #expect(Platform27.capabilities(hiding: .available, trusted: true, tracking: .full, reordering: .available).menuTracking == .full)
    #expect(
        Platform27.capabilities(hiding: .available, trusted: true, tracking: .unavailable, reordering: .available).menuTracking
            == .unavailable
    )
}

private func makeEngine(_ source: FakeWindowSource, _ exits: ExitSource = ExitSource()) -> MenuTracker27.Session {
    MenuTracker27.Session(source: source, queue: AXQueue(), exits: { exits.exits(of: $0) }, after: nil) { _, _, _ in }
}

/// A cancelled task that iterates an `AsyncStream` can still be handed an element that was buffered before it
/// was cancelled. So an engine that has been stopped must ignore such late input.
@Test(.timeLimit(.minutes(1))) func aStoppedEngineIgnoresALateGrant() async {
    let source = FakeWindowSource(granted: true)
    let engine = makeEngine(source)
    await engine.processesChanged([10, 20])
    await engine.stop().value

    await engine.trustChanged(true)
    await engine.processesChanged([10, 20, 30])
    await engine.finishedLaunching(10)
    #expect(source.attachCalls.isEmpty)
    #expect(source.liveObservers.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func anAttachThatFinishesAfterTheEngineStoppedIsDetached() async {
    let source = FakeWindowSource(granted: true)
    let engine = makeEngine(source)
    source.holdNextAttach(10)
    await engine.processesChanged([10, 20])
    var started = source.heldAttachStarted.makeAsyncIterator()
    let granting = Task { await engine.trustChanged(true) }
    #expect(await started.next() == 10)

    let stopping = engine.stop()
    source.release(10, succeeding: true)
    await granting.value
    await stopping.value
    #expect(source.liveObservers.isEmpty)
    #expect(Set(source.detached.map(\.rawValue)) == Set(source.attachedTokens.map(\.rawValue)))
}

@Test(.timeLimit(.minutes(1))) func anAppThatQuitDuringItsAttachLeavesNoFailureRecord() async {
    let source = FakeWindowSource(granted: true)
    let engine = makeEngine(source)
    source.failEveryAttach(10)
    source.holdNextAttach(10)
    await engine.processesChanged([10, 20])
    var started = source.heldAttachStarted.makeAsyncIterator()
    let granting = Task { await engine.trustChanged(true) }
    #expect(await started.next() == 10)

    // The app quits while its attach is in flight, and then that attach fails.
    await engine.processesChanged([20])
    source.release(10, succeeding: false)
    await granting.value

    // It runs again: with no stale record the failure is new, so it gets its one retry on the next change.
    await engine.processesChanged([20, 10])
    await engine.processesChanged([20, 10, 40])
    #expect(source.attachCalls.filter { $0 == 10 }.count == 3)
}


/// The tracking values an engine has published, in order.
private final class PublishedTracking: Sendable {
    private let values = OSAllocatedUnfairLock<[MenuTracking]>(initialState: [])
    var all: [MenuTracking] { values.withLock { $0 } }
    var last: MenuTracking? { all.last }
    func record(_ tracking: MenuTracking?) {
        if let tracking { values.withLock { $0.append(tracking) } }
    }
}

private func makeRecordedEngine(
    _ source: FakeWindowSource, _ published: PublishedTracking, _ exits: ExitSource = ExitSource()
) -> MenuTracker27.Session {
    MenuTracker27.Session(source: source, queue: AXQueue(), exits: { exits.exits(of: $0) }, after: nil) { _, _, tracking in
        published.record(tracking)
    }
}

// Catches `.full` reported while a process that draws a bar item is not attached: its menus would go unseen, and the
// bar would rehide over an open menu.
@Test(.timeLimit(.minutes(1))) func aCoveredProcessWhoseAttachFailedMakesTrackingPartial() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    source.failEveryAttach(10)
    await engine.coveredChanged([10])
    await engine.processesChanged([10, 20])
    await engine.trustChanged(true)
    #expect(published.last == .partial)
    #expect(!published.all.contains(.full))
}

// Catches coverage keyed by bundle identity: a process that draws an item but has no bundle identifier is just a
// pid to the tracker, and its failed attach must show.
@Test(.timeLimit(.minutes(1))) func anUnresolvedOwnerWhoseAttachFailsMakesTrackingPartial() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    source.failEveryAttach(30)
    await engine.coveredChanged([10, 30])
    await engine.processesChanged([10, 30])
    await engine.trustChanged(true)
    #expect(published.last == .partial)
    #expect(!published.all.contains(.full))
}

@Test(.timeLimit(.minutes(1))) func aCoveredProcessThatAttachesLaterRestoresFullTracking() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    source.failNextAttach(10)
    await engine.coveredChanged([10])
    await engine.processesChanged([10])
    await engine.trustChanged(true)
    #expect(published.last == .partial)

    await engine.finishedLaunching(10)
    #expect(published.last == .full)
    #expect(source.attachCalls == [10, 10])
}

@Test(.timeLimit(.minutes(1))) func aProcessThatDrawsNoItemDoesNotAffectTracking() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    source.failEveryAttach(20)
    await engine.coveredChanged([10])
    await engine.processesChanged([10, 20])
    await engine.trustChanged(true)
    #expect(published.last == .full)
    #expect(!published.all.contains(.partial))
}

@Test(.timeLimit(.minutes(1))) func aProcessLeavingTheCoverageSetRestoresFullTracking() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    source.failEveryAttach(10)
    await engine.coveredChanged([10, 20])
    await engine.processesChanged([10, 20])
    await engine.trustChanged(true)
    #expect(published.last == .partial)

    // It no longer draws an item.
    await engine.coveredChanged([20])
    #expect(published.last == .full)

    // It draws one again, then quits: quitting alone keeps tracking partial while its item is drawn.
    await engine.coveredChanged([10, 20])
    #expect(published.last == .partial)
    await engine.processesChanged([20])
    #expect(published.last == .partial)

    // The scan drops it.
    await engine.coveredChanged([20])
    #expect(published.last == .full)
}

@Test func trackingIsFullOnlyWhenEveryCoveredProcessIsAttached() {
    #expect(TrackingCoverage.tracking(covered: [], attached: []) == .full)
    #expect(TrackingCoverage.tracking(covered: [1], attached: [1, 2]) == .full)
    #expect(TrackingCoverage.tracking(covered: [1, 2], attached: [1]) == .partial)
    #expect(TrackingCoverage.tracking(covered: [1], attached: []) == .partial)
}

/// Reads of `pid` from `log`, until `count` of them have arrived: a read is the one sign that an input was handled.
private func waitForReads(of pid: pid_t, _ count: Int, in log: AsyncStream<pid_t>) async {
    var iterator = log.makeAsyncIterator()
    var seen = 0
    while let read = await iterator.next() {
        if read == pid { seen += 1 }
        if seen == count { return }
    }
}

// Plan review P1: catches every reveal of a hidden helper setting its observer up again, publishing `.partial` and
// cancelling the rehide the reveal just scheduled.
@Test(.timeLimit(.minutes(1))) func aHelperWhoseItemStopsBeingDrawnKeepsItsObserver() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.processesChanged([10])
    await engine.coveredChanged([10, 30])
    await engine.trustChanged(true)
    #expect(source.attachCalls.sorted() == [10, 30])
    #expect(published.last == .full)

    await engine.coveredChanged([10])
    #expect(source.detached.isEmpty)

    await engine.coveredChanged([10, 30])
    #expect(source.attachCalls.count == 2)
    #expect(!published.all.contains(.partial))
}

@Test(.timeLimit(.minutes(1))) func aHelperIsDetachedWhenItsProcessExits() async {
    let source = FakeWindowSource(granted: true)
    let exits = ExitSource()
    let engine = makeEngine(source, exits)
    await engine.processesChanged([10])
    await engine.coveredChanged([10, 30])
    await engine.trustChanged(true)
    await engine.coveredChanged([10])
    var detached = source.detachLog.makeAsyncIterator()

    exits.exit(30)
    #expect(await detached.next() != nil)
    #expect(source.detached.count == 1)
    #expect(source.liveObservers == [10])

    // A new process with the same pid: attached again.
    await engine.coveredChanged([10, 30])
    #expect(source.attachCalls.filter { $0 == 30 }.count == 2)
    #expect(source.liveObservers.sorted() == [10, 30])
}

// Catches a partial blip when a helper quits while its item is still drawn.
@Test(.timeLimit(.minutes(1))) func anExitedHelperStillDrawnKeepsItsObserverUntilTheScanDropsIt() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let exits = ExitSource()
    let engine = makeRecordedEngine(source, published, exits)
    await engine.processesChanged([])
    await engine.coveredChanged([10, 30])
    await engine.trustChanged(true)
    #expect(published.last == .full)

    exits.exit(30)
    // Its exit reads it again: the grant read it once, so the second read says the exit was handled.
    await waitForReads(of: 30, 2, in: source.readLog)
    #expect(source.detached.isEmpty)
    #expect(published.last == .full)

    await engine.coveredChanged([10])
    #expect(source.detached.count == 1)
    #expect(source.liveObservers == [10])
    #expect(!published.all.contains(.partial))
}

// Round 3 P1 and Decision A: catches a drawn owner with a prohibited policy, or missing from NSWorkspace, treated as
// gone.
@Test(.timeLimit(.minutes(1))) func aDrawnProcessThatIsNotATrackableAppIsAttachedAndCovered() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.coveredChanged([10, 30])
    await engine.processesChanged([10])
    await engine.trustChanged(true)
    #expect(source.attachCalls.sorted() == [10, 30])
    #expect(published.last == .full)

    let failing = FakeWindowSource(granted: true)
    failing.failEveryAttach(30)
    let failedPublished = PublishedTracking()
    let failedEngine = makeRecordedEngine(failing, failedPublished)
    await failedEngine.coveredChanged([10, 30])
    await failedEngine.processesChanged([10])
    await failedEngine.trustChanged(true)
    #expect(failedPublished.last == .partial)

    await failedEngine.coveredChanged([10])
    #expect(failedPublished.last == .full)
    #expect(failing.detached.isEmpty)
}

// Catches a partial blip on every quit, which would cancel a pending rehide under R55.
@Test(.timeLimit(.minutes(1))) func anAttachedAppThatQuitsKeepsItsObserverUntilItsItemLeaves() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let exits = ExitSource()
    let engine = makeRecordedEngine(source, published, exits)
    await engine.processesChanged([10])
    await engine.coveredChanged([10])
    await engine.trustChanged(true)
    #expect(published.last == .full)

    await engine.processesChanged([])
    exits.exit(10)
    // The grant, leaving the process list and the exit each read it.
    await waitForReads(of: 10, 3, in: source.readLog)
    #expect(source.detached.isEmpty)
    #expect(published.last == .full)

    await engine.coveredChanged([])
    #expect(source.detached.count == 1)
    #expect(!published.all.contains(.partial))
}

// Review of this task, finding 2: catches a covered-only pid attached and counted as watched while its events and
// reads are dropped. Attach counts alone would pass with the bug; this reads the open values.
@Test(.timeLimit(.minutes(1))) func aMenuOnACoveredOnlyProcessIsSeenOpenAndClosed() async {
    let harness = Harness(showingMenu: [30], granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    var open = tracker.values().makeAsyncIterator()
    #expect(await open.next() == false)
    harness.processes.send([10])
    harness.covered.send([10, 30])
    harness.trust.send(true)
    #expect(await open.next() == true)

    source.setShowingMenu([])
    source.send(30)
    #expect(await open.next() == false)

    source.setShowingMenu([30])
    source.send(30)
    #expect(await open.next() == true)
}

// Catches a quit app's open menu held until the next scan.
@Test(.timeLimit(.minutes(1))) func aQuitProcessStillCoveredIsReadAgainAndClosesItsMenu() async {
    let harness = Harness(showingMenu: [20], granted: true)
    let (source, tracker) = (harness.source, harness.tracker)
    var open = tracker.values().makeAsyncIterator()
    #expect(await open.next() == false)
    harness.processes.send([20])
    var watching = harness.exits.subscriptionLog.makeAsyncIterator()
    harness.covered.send([20])
    harness.trust.send(true)
    #expect(await open.next() == true)
    // The exit comes after the covered input has been handled, whichever input the menu was first read from.
    #expect(await watching.next() == 20)

    source.setShowingMenu([])
    harness.processes.send([])
    harness.exits.exit(20)
    #expect(await open.next() == false)
    #expect(source.detached.isEmpty)

    var detached = source.detachLog.makeAsyncIterator()
    harness.covered.send([])
    #expect(await detached.next() != nil)
    #expect(source.liveObservers.isEmpty)
}

// Review of this task, finding 3: catches a stale `.full` while a launching app's item is drawn before its observer
// has registered.
@Test(.timeLimit(.minutes(1))) func aCoveredProcessStillAttachingMakesTrackingPartialUntilItRegisters() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.processesChanged([10])
    await engine.coveredChanged([10])
    await engine.trustChanged(true)
    #expect(published.last == .full)

    source.holdNextAttach(30)
    var started = source.heldAttachStarted.makeAsyncIterator()
    let appearing = Task { await engine.processesChanged([10, 30]) }
    #expect(await started.next() == 30)
    await engine.coveredChanged([10, 30])
    #expect(published.last == .partial)

    source.release(30, succeeding: true)
    await appearing.value
    #expect(published.last == .full)
}

// Review of this task, M1: catches a partial at every launch when trust is handled before the inputs that say what
// to attach. Nothing is published until the tracker knows what it watches and has attached it.
@Test(.timeLimit(.minutes(1))) func theGrantPublishesNothingUntilBothInputsHaveArrivedInAnyOrder() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.trustChanged(true)
    #expect(published.all.isEmpty)

    source.holdNextAttach(30)
    var started = source.heldAttachStarted.makeAsyncIterator()
    let appearing = Task { await engine.processesChanged([10, 30]) }
    #expect(await started.next() == 30)
    await engine.coveredChanged([10, 30])
    #expect(published.all.isEmpty)

    source.release(30, succeeding: true)
    await appearing.value
    #expect(published.all == [.full])
}

// Catches the grant settling on one input alone: with trust first, the tracker is silent until it has been told both
// what is running and what is covered, whichever comes first. Settling on `processes` alone would publish `.full`
// before the covered helper's attach starts; settling on `covered` alone would publish before the running apps are
// known.
@Test(.timeLimit(.minutes(1))) func theGrantStaysSilentUntilTheOtherInputHasArrivedToo() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.trustChanged(true)
    await engine.processesChanged([10])
    #expect(published.all.isEmpty)

    source.holdNextAttach(30)
    var started = source.heldAttachStarted.makeAsyncIterator()
    let covering = Task { await engine.coveredChanged([10, 30]) }
    #expect(await started.next() == 30)
    #expect(published.all.isEmpty)

    source.release(30, succeeding: true)
    await covering.value
    #expect(published.all == [.full])

    let other = FakeWindowSource(granted: true)
    let otherPublished = PublishedTracking()
    let otherEngine = makeRecordedEngine(other, otherPublished)
    await otherEngine.trustChanged(true)
    await otherEngine.coveredChanged([10])
    #expect(otherPublished.all.isEmpty)

    await otherEngine.processesChanged([10, 30])
    #expect(otherPublished.all == [.full])
}

// Review of this task, M3: catches an observer registered before a revocation counting as attached after the
// re-grant. The new round attaches again and the old token is let go.
@Test(.timeLimit(.minutes(1))) func anAttachBegunBeforeARevocationIsDiscardedAfterTheReGrant() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.processesChanged([10])
    await engine.coveredChanged([10])
    source.holdNextAttach(10)
    var started = source.heldAttachStarted.makeAsyncIterator()
    let granting = Task { await engine.trustChanged(true) }
    #expect(await started.next() == 10)

    await engine.trustChanged(false)
    await engine.trustChanged(true)
    #expect(source.attachCalls == [10, 10])

    var detached = source.detachLog.makeAsyncIterator()
    source.release(10, succeeding: true)
    await granting.value
    #expect(await detached.next() != nil)
    #expect(source.liveObservers == [10])
    #expect(published.last == .full)
}

// Guards the one exception to publishing at once: from the grant until its attach round has settled, the value stays
// unavailable, so a launch doesn't show a partial.
@Test(.timeLimit(.minutes(1))) func theGrantPublishesOnceItsAttachRoundHasSettled() async {
    let source = FakeWindowSource(granted: true)
    let published = PublishedTracking()
    let engine = makeRecordedEngine(source, published)
    await engine.processesChanged([10, 30])
    await engine.coveredChanged([10, 30])
    source.holdNextAttach(30)
    var started = source.heldAttachStarted.makeAsyncIterator()
    let granting = Task { await engine.trustChanged(true) }
    #expect(await started.next() == 30)

    source.release(30, succeeding: true)
    await granting.value

    #expect(published.all == [.full])
}

@Test(.timeLimit(.minutes(1))) func coverageIsTheUnionOfWhatIsDrawnAndTheSystemOwnersOnceBothAreKnown() async {
    let drawn = Feed<Set<pid_t>>()
    let system = Feed<Set<pid_t>>()
    var union = TrackingCoverage.union(drawn.stream(), system.stream()).makeAsyncIterator()

    drawn.send([10])
    system.send([90])
    #expect(await union.next() == [10, 90])
    drawn.send([10, 30])
    #expect(await union.next() == [10, 30, 90])
    system.send([91])
    #expect(await union.next() == [10, 30, 91])
}

@Test func theSystemOwnersAreControlCenterAndNotificationCenter() {
    #expect(TrackingCoverage.systemOwners == ["com.apple.controlcenter", "com.apple.notificationcenterui"])
}

// Catches the live bug: a closed status-item menu stays in the tree as an AXMenu of size 0x0, so counting every
// AXMenu read as open while every menu was closed and the rehide never fired.
@Test func aMenuWithNoSizeIsClosedAndOneWithAnAreaIsOpen() {
    #expect(!MenuRule.isOpen(size: CGSize(width: 0, height: 0)))
    #expect(!MenuRule.isOpen(size: CGSize(width: 0, height: 796)))
    #expect(!MenuRule.isOpen(size: CGSize(width: 242, height: 0)))
    #expect(MenuRule.isOpen(size: CGSize(width: 242, height: 796)))
    #expect(MenuRule.isOpen(size: CGSize(width: 1, height: 1)))
}
