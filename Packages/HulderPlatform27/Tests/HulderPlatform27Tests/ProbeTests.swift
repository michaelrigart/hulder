#if DEBUG
import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

private func item(_ key: String, at position: Double?, owner: ItemOwner = .app(AppID("com.example.a"), name: "A")) -> MenuBarItem {
    MenuBarItem(key: ItemKey(raw: key), owner: owner, barPosition: position)
}

private func complete(_ items: [MenuBarItem], owner: ItemOwner = .app(AppID("com.example.a"), name: "A")) -> AppScan {
    AppScan(owner: owner, result: .complete(items))
}

// Catches an items-watch that misses an item appearing, going or sliding along the bar.
@Test func scanDiffReportsAppearedDisappearedAndMovedItems() {
    let old = [complete([item("a", at: 100), item("b", at: 130)])]
    let new = [complete([item("a", at: 150), item("c", at: 130)])]
    let changes = ProbeScanLog.diff(old: old, new: new)
    #expect(changes.contains { $0.hasPrefix("appeared com.example.a c") })
    #expect(changes.contains { $0.hasPrefix("disappeared com.example.a b") })
    #expect(changes.contains { $0.hasPrefix("moved com.example.a a 100.0 -> 150.0") })
    #expect(changes.count == 3)
}

// Catches an item's accessibility title or description reaching the public part of a probe line: both are the user's
// own text and are logged at `.private`.
@Test func anItemsTitleAndDescriptionAreNeverInThePublicPartOfItsLine() {
    let owner = ItemOwner.app(AppID("com.example.a"), name: "A")
    let described = MenuBarItem(
        key: ItemKey(raw: "status:com.example.a::Item-0"), owner: owner, description: "Alice's Mac", title: "Inbox (3)",
        barPosition: 100)

    let line = ProbeScanLog.describe(described)
    #expect(line.text == "key=status:com.example.a::Item-0 barPosition=100.0 managedByMacOS=false")
    #expect(line.personal == " desc=Alice's Mac title=Inbox (3)")

    let lines = ProbeScanLog.lines([complete([described])])
    #expect(lines.map(\.text) == ["owner=com.example.a key=status:com.example.a::Item-0 barPosition=100.0 managedByMacOS=false"])
    #expect(lines.allSatisfy { !$0.text.contains("Alice") && !$0.text.contains("Inbox") })
    #expect(lines.map(\.personal) == [" desc=Alice's Mac title=Inbox (3)"])
}

@Test func scanDiffIgnoresSubPointMovesAndReportsOwnersThatStopReading() {
    let old = [complete([item("a", at: 100)])]
    #expect(ProbeScanLog.diff(old: old, new: [complete([item("a", at: 100.4)])]).isEmpty)
    let timedOut = [AppScan(owner: .app(AppID("com.example.a"), name: "A"), result: .timedOut)]
    #expect(ProbeScanLog.diff(old: old, new: timedOut).contains("owner com.example.a complete -> timedOut"))
}

@Test func moveLandsImmediatelyLeftOfTheAnchor() {
    let keys = ["a", "b", "c", "d"].map(ItemKey.init(raw:))
    let order = BarOrder(keys: keys, pinned: [])
    let change = ProbeOrderLog.move(ItemKey(raw: "d"), before: ItemKey(raw: "b"), in: order)
    #expect(change?.target.map(\.raw) == ["a", "d", "b", "c"])
    #expect(change?.moved.map(\.raw) == ["d"])
}

@Test func moveIsNilWhenNothingWouldChangeOrAKeyIsMissing() {
    let order = BarOrder(keys: ["a", "b", "c"].map(ItemKey.init(raw:)), pinned: [])
    #expect(ProbeOrderLog.move(ItemKey(raw: "a"), before: ItemKey(raw: "b"), in: order) == nil)
    #expect(ProbeOrderLog.move(ItemKey(raw: "a"), before: ItemKey(raw: "z"), in: order) == nil)
    #expect(ProbeOrderLog.move(ItemKey(raw: "a"), before: ItemKey(raw: "a"), in: order) == nil)
}

@Test func orderDiffReportsAddedRemovedAndMovedKeys() {
    let old = BarOrder(keys: ["a", "b", "c"].map(ItemKey.init(raw:)), pinned: [])
    let new = BarOrder(keys: ["c", "a", "d"].map(ItemKey.init(raw:)), pinned: [])
    let changes = ProbeOrderLog.diff(old: old, new: new)
    #expect(changes.contains("added d"))
    #expect(changes.contains("removed b"))
    #expect(changes.contains { $0.hasPrefix("moved c ") })
}

@Test func positionsDiffLeavesOutTheExcludedKey() {
    let old = ["a": 10.0, "b": 20.0, "c": 30.0]
    let new = ["a": 10.0, "b": 20.001, "c": 30.0, "d": 5.0]
    let changes = ProbeOrderLog.diff(old: old, new: new, excluding: "b")
    #expect(changes == ["added d 5.0"])
    #expect(ProbeOrderLog.diff(old: old, new: new).count == 2)
}

// Catches a probe whose maxSystemItem override or default bypasses the translation the backend ships.
@Test func backendTranslatesTheAllowListThroughItsTranslation() async {
    let seen = Mutex<AllowList?>(nil)
    let backend = AssertionBackend27(core: MenuBarClientCore(resolver: .frameworkMissing)) { list in
        seen.withLock { $0 = list }
        return ([], [])
    }
    let list = AllowList(apps: [AppID("com.example.a")])
    _ = try? await backend.prepare(list)
    #expect(seen.withLock { $0 } == list)
}

/// A clock whose sleeps end only when the test says so (or are cancelled), whatever their length.
private final class OnDemandClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var released = false
        var nextID = 0
        var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    /// Ends every sleep, including those that start later.
    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.released = true
            defer { state.sleepers = [:] }
            return Array(state.sleepers.values)
        }
        waiting.forEach { $0.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.released { return .success(()) }
                    state.sleepers[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

// Catches the probe blocking the main actor on the framework's queue: a stuck queue must cost the timeout, not the
// probe. The queue here never runs the barrier until the test lets it.
@MainActor @Test(.timeLimit(.minutes(1))) func aQueueThatDoesNotDrainEndsTheWaitAtTheTimeout() async {
    let clock = OnDemandClock()
    let runner = ProbeRunner(clock: clock)
    let queue = DispatchQueue(label: "test.stuck")
    let stuck = DispatchSemaphore(value: 0)
    queue.async { stuck.wait() }

    let waiting = Task { @MainActor in await runner.drained(queue) }
    clock.release()
    let drained = await waiting.value
    stuck.signal()

    #expect(drained == false)
}

@MainActor @Test(.timeLimit(.minutes(1))) func aQueueThatDrainsEndsTheWaitBeforeTheTimeout() async {
    let runner = ProbeRunner(clock: OnDemandClock())
    let queue = DispatchQueue(label: "test.free")
    var ran = false
    queue.async {}

    ran = await runner.drained(queue)

    #expect(ran)
}
#endif
