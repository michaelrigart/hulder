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

/// A window source whose Accessibility state the test controls.
private final class FakeWindowSource: MenuWindowSource {
    private struct State {
        var granted = false
        var showingMenu: Set<pid_t> = []
        var attachFailuresLeft: [pid_t: Int] = [:]
        var attached: [pid_t] = []
        var attachCalls: [pid_t] = []
        var reads: [pid_t] = []
        /// Calls made while the grant was missing.
        var callsWithoutGrant = 0
        var subscribers: [UUID: AsyncStream<pid_t>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readContinuation: AsyncStream<pid_t>.Continuation
    /// Yields the process of every `isOpen` call, in order.
    let readLog: AsyncStream<pid_t>

    init(showingMenu: Set<pid_t> = [], granted: Bool = false) {
        (readLog, readContinuation) = AsyncStream<pid_t>.makeStream()
        state.withLock { $0.showingMenu = showingMenu; $0.granted = granted }
    }

    var attached: [pid_t] { state.withLock { $0.attached } }
    var attachCalls: [pid_t] { state.withLock { $0.attachCalls } }
    var reads: [pid_t] { state.withLock { $0.reads } }
    var callsWithoutGrant: Int { state.withLock { $0.callsWithoutGrant } }

    func grant() { state.withLock { $0.granted = true } }
    func setShowingMenu(_ pids: Set<pid_t>) { state.withLock { $0.showingMenu = pids } }
    func failNextAttach(_ pid: pid_t) { state.withLock { $0.attachFailuresLeft[pid] = 1 } }

    func send(_ pid: pid_t) {
        state.withLock { state in state.subscribers.values.forEach { $0.yield(pid) } }
    }

    func events() -> AsyncStream<pid_t> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { $0.subscribers[id] = continuation }
            continuation.onTermination = { [state] _ in state.withLock { $0.subscribers[id] = nil } }
        }
    }

    func attach(_ pid: pid_t) -> Bool {
        state.withLock { state in
            state.attachCalls.append(pid)
            guard state.granted else {
                state.callsWithoutGrant += 1
                return false
            }
            if let left = state.attachFailuresLeft[pid], left > 0 {
                state.attachFailuresLeft[pid] = left - 1
                return false
            }
            state.attached.append(pid)
            return true
        }
    }

    func detach(_ pid: pid_t) {}

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
    let tracker: MenuTracker27

    init(showingMenu: Set<pid_t> = [], granted: Bool = false) {
        let source = FakeWindowSource(showingMenu: showingMenu, granted: granted)
        let (trust, processes, launched) = (trust, processes, launched)
        self.source = source
        tracker = MenuTracker27(
            source: source,
            queue: AXQueue(),
            trust: { trust.stream() },
            processes: { processes.stream() },
            launched: { launched.stream() }
        )
    }
}

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

@Test func aStandardWindowAtTheBarIsNotAMenu() {
    #expect(!WindowRule.isOpen(subrole: "AXStandardWindow", top: 24, barBottom: 24))
}

@Test func aNonStandardWindowAtTheBarIsAMenu() {
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", top: 24, barBottom: 24))
    #expect(WindowRule.isOpen(subrole: "AXSystemDialog", top: 25.9, barBottom: 24))
    #expect(WindowRule.isOpen(subrole: nil, top: 24, barBottom: 24))
}

@Test func aNonStandardWindowBelowTheBarIsNotAMenu() {
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", top: 34, barBottom: 24))
    #expect(!WindowRule.isOpen(subrole: "AXSystemDialog", top: 24, barBottom: nil))
}
