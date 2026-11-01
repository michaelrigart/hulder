import Darwin
import os
import Testing
@testable import HulderPlatform27

/// A window source whose Accessibility state the test controls.
private final class FakeWindowSource: MenuWindowSource {
    private struct State {
        var granted = false
        var showingMenu: Set<pid_t> = []
        var attached: [pid_t] = []
        var reads: [pid_t] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let eventContinuation: AsyncStream<pid_t>.Continuation
    private let readContinuation: AsyncStream<pid_t>.Continuation
    let events: AsyncStream<pid_t>
    /// Yields the process of every `isOpen` call, in order.
    let readLog: AsyncStream<pid_t>

    init(showingMenu: Set<pid_t>) {
        (events, eventContinuation) = AsyncStream<pid_t>.makeStream()
        (readLog, readContinuation) = AsyncStream<pid_t>.makeStream()
        state.withLock { $0.showingMenu = showingMenu }
    }

    var attached: [pid_t] { state.withLock { $0.attached } }
    var reads: [pid_t] { state.withLock { $0.reads } }

    func grant() { state.withLock { $0.granted = true } }
    func setShowingMenu(_ pids: Set<pid_t>) { state.withLock { $0.showingMenu = pids } }
    func send(_ pid: pid_t) { eventContinuation.yield(pid) }

    func attach(_ pid: pid_t) -> Bool {
        state.withLock { state in
            guard state.granted else { return false }
            state.attached.append(pid)
            return true
        }
    }

    func detach(_ pid: pid_t) {}

    func isOpen(_ pid: pid_t) -> Bool {
        let open = state.withLock { state -> Bool in
            state.reads.append(pid)
            return state.showingMenu.contains(pid)
        }
        readContinuation.yield(pid)
        return open
    }
}

@Test(.timeLimit(.minutes(1))) func grantAfterDeniedStartAttachesAndReads() async {
    let source = FakeWindowSource(showingMenu: [20])
    let trust = AsyncStream<Bool>.makeStream()
    let processes = AsyncStream<Set<pid_t>>.makeStream()
    let tracker = MenuTracker27(source: source, queue: AXQueue(), trust: { trust.stream }, processes: { processes.stream })
    var open = tracker.values().makeAsyncIterator()

    // Untrusted start: the current value comes first, and nothing is open.
    #expect(await open.next() == false)
    processes.continuation.yield([10, 20])
    trust.continuation.yield(false)
    #expect(tracker.tracking == .unavailable)
    #expect(source.reads.isEmpty)

    // The grant: attach to both apps, read each once, so the open menu counts.
    source.grant()
    trust.continuation.yield(true)
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
}

@Test(.timeLimit(.minutes(1))) func quittingTheOpenAppClosesItsMenu() async {
    let source = FakeWindowSource(showingMenu: [20])
    source.grant()
    let trust = AsyncStream<Bool>.makeStream()
    let processes = AsyncStream<Set<pid_t>>.makeStream()
    let tracker = MenuTracker27(source: source, queue: AXQueue(), trust: { trust.stream }, processes: { processes.stream })
    var open = tracker.values().makeAsyncIterator()
    #expect(await open.next() == false)
    processes.continuation.yield([10, 20])
    trust.continuation.yield(true)
    #expect(await open.next() == true)

    processes.continuation.yield([10])
    #expect(await open.next() == false)
}

@Test(.timeLimit(.minutes(1))) func losingTheGrantClearsOpenMenusAndTheCapability() async {
    let source = FakeWindowSource(showingMenu: [20])
    source.grant()
    let trust = AsyncStream<Bool>.makeStream()
    let processes = AsyncStream<Set<pid_t>>.makeStream()
    let tracker = MenuTracker27(source: source, queue: AXQueue(), trust: { trust.stream }, processes: { processes.stream })
    var open = tracker.values().makeAsyncIterator()
    #expect(await open.next() == false)
    processes.continuation.yield([20])
    trust.continuation.yield(true)
    #expect(await open.next() == true)

    trust.continuation.yield(false)
    #expect(await open.next() == false)
    #expect(tracker.tracking == .unavailable)
}

@Test func aWindowAnchoredAtTheBarCountsAsAMenu() {
    #expect(WindowRule.isAnchored(top: 24, barBottom: 24))
    #expect(WindowRule.isAnchored(top: 25.9, barBottom: 24))
    #expect(WindowRule.isAnchored(top: 22, barBottom: 24))
    #expect(!WindowRule.isAnchored(top: 26.5, barBottom: 24))
    #expect(!WindowRule.isAnchored(top: 300, barBottom: 24))
    #expect(!WindowRule.isAnchored(top: 24, barBottom: nil))
}
