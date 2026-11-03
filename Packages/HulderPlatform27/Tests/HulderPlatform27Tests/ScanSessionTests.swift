import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

/// Events a test waits for, in order. One test body reads it, one call at a time. A wait that nothing satisfies
/// gives nil after `timeout`, so a missing event fails the test instead of hanging it.
private final class Inbox<Value: Sendable>: @unchecked Sendable { // reason: a single reader; the iterator is never used concurrently
    private let continuation: AsyncStream<Value>.Continuation
    private var iterator: AsyncStream<Value>.Iterator

    init() {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    func send(_ value: Value) { continuation.yield(value) }

    func next(timeout: Duration = .seconds(5)) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await self.iterator.next() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Lets the async hops that follow an event finish before a test asserts that something did not happen.
private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

/// A clock that only moves when the test says so. Every sleep asks for its duration through `requests` and is
/// woken by a release; a sleep that is cancelled instead is reported through `cancellations`.
private final class FakeSleeper: Sendable {
    let requests = Inbox<Duration>()
    let cancellations = Inbox<Void>()
    private let gates = Mutex<[AsyncStream<Void>.Continuation]>([])
    private let requested = Mutex(0)

    var requestCount: Int { requested.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        gates.withLock { $0.append(release) }
        requested.withLock { $0 += 1 }
        requests.send(duration)
        for await _ in gate { break }
        if Task.isCancelled {
            cancellations.send(())
            throw CancellationError()
        }
    }

    /// Wakes the sleep that was requested last.
    func releaseNewest() { gates.withLock { $0.popLast() }?.yield() }

    func releaseAll() { gates.withLock { let all = $0; $0 = []; return all }.forEach { $0.yield() } }
}

/// The bar, read as the script says: a pass that reads it, one that cannot, or one that reads it only once the test
/// releases it. A read the script has no step for records an issue.
private final class ScriptedBar: Sendable {
    enum Step: Sendable { case read, unread, held }

    let started = Inbox<Void>()
    let agentPID: pid_t?
    private let script: Mutex<[Step]>
    private let reads = Mutex(0)
    private let gate = AsyncStream<Void>.makeStream()

    init(_ script: [Step], agentPID: pid_t?) {
        self.script = Mutex(script)
        self.agentPID = agentPID
    }

    var readCount: Int { reads.withLock { $0 } }

    func read(_: AXQueue) async -> BarReading {
        reads.withLock { $0 += 1 }
        started.send(())
        let step = script.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if step == nil { Issue.record("the scanner read the bar \(readCount) times; the script has fewer steps") }
        if step == .held { for await _ in gate.0 { break } }
        let snapshot = step == .unread || step == nil ? nil : BarSnapshot(groups: [], overflowIndicatorX: nil)
        return BarReading(
            snapshot: snapshot, owners: [:], running: [], agentPID: agentPID, listings: [:], readDuration: .zero)
    }

    func release() { gate.1.yield() }
}

/// MenuBarAgent, attached to or not, recording each attach and each invalidation.
private final class FakeAgent: Sendable {
    let attaches = Inbox<Void>()
    let invalidations = Inbox<Void>()
    private let observable: Bool
    private let attached = Mutex(0)

    init(observable: Bool) { self.observable = observable }

    var attachCount: Int { attached.withLock { $0 } }

    func attach(_: AXQueue, _: @escaping @Sendable (pid_t) -> Void) async -> MenuBarScanner27.AgentAttachment? {
        attached.withLock { $0 += 1 }
        attaches.send(())
        guard observable else { return MenuBarScanner27.AgentAttachment(pid: 7, invalidate: nil) }
        let invalidations = invalidations
        return MenuBarScanner27.AgentAttachment(pid: 7, invalidate: { invalidations.send(()) })
    }
}

/// A scanner with a session that the test drives: `trust` and `apps` are its streams, the bar and the clock are
/// scripted, and `passes` receives what `scans()` emits.
private struct Rig {
    let trust: AsyncStream<Bool>.Continuation
    let apps: AsyncStream<Set<AppID>>.Continuation
    let bar: ScriptedBar
    let sleeper: FakeSleeper
    let agent: FakeAgent
    let passes: Inbox<ScanPass>
    /// Each pass that has read the bar, before the session finishes with it.
    let barRead: Inbox<Void>
    let scanner: MenuBarScanner27
    private let consumer: Task<Void, Never>

    init(
        _ script: [ScriptedBar.Step], agentPID: pid_t? = nil, observableAgent: Bool = false,
        concealedSystemItems: Set<SystemItemID> = []
    ) {
        let (trustStream, trust) = AsyncStream<Bool>.makeStream()
        let (appsStream, apps) = AsyncStream<Set<AppID>>.makeStream()
        let bar = ScriptedBar(script, agentPID: agentPID)
        let sleeper = FakeSleeper()
        let agent = FakeAgent(observable: observableAgent)
        let barRead = Inbox<Void>()
        let scanner = MenuBarScanner27(
            queue: AXQueue(), trust: { trustStream }, apps: { appsStream }, entries: { [:] },
            concealed: { _ in
                barRead.send(())
                return []
            },
            concealedSystemItems: { concealedSystemItems },
            own: AppID("com.example.hulder"), readBar: bar.read, attachAgent: agent.attach, sleep: sleeper.sleep)
        let passes = Inbox<ScanPass>()
        (self.trust, self.apps, self.bar, self.sleeper, self.agent) = (trust, apps, bar, sleeper, agent)
        (self.passes, self.barRead, self.scanner) = (passes, barRead, scanner)
        consumer = Task { for await pass in scanner.scans() { passes.send(pass) } }
    }

    /// Ends the `scans()` subscription, which stops its session.
    func stop() { consumer.cancel() }
}

private func isRead(_ pass: ScanPass?) -> Bool { pass?.drawn != nil }

private let retryDelay = Duration.milliseconds(500)

/// A rig that has finished a pass that read the bar, then one that could not, so a retry is pending.
private func rigWithPendingRetry() async -> Rig {
    let rig = Rig([.read, .unread])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))
    rig.scanner.requestScan()
    #expect(await rig.passes.next() == .unread)
    #expect(await rig.sleeper.requests.next() == retryDelay)
    return rig
}

// Catches the backend's hidden modules never reaching the pass: Layout would drop them while they are hidden.
@Test(.timeLimit(.minutes(1))) func theConcealedSystemItemsReachThePass() async throws {
    let wifi = SystemItemID(moduleName: "WiFi")
    let rig = Rig([.read], concealedSystemItems: [wifi])
    rig.trust.yield(true)
    let pass = try #require(await rig.passes.next())
    #expect(pass.concealed.flatMap(\.items).map(\.systemItem) == [wifi])
    rig.stop()
}

// Catches the retry not being scheduled after a pass that could not read the bar, which leaves the inventory
// stale until some unrelated event. Mutation: delete `unreadRetry.restart` from `drain()`.
@Test(.timeLimit(.minutes(1))) func anUnreadPassAfterAReadOneIsRetriedOnceAfterTheRetryDelay() async {
    let rig = Rig([.read, .unread, .read])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))
    rig.scanner.requestScan()
    #expect(await rig.passes.next() == .unread)
    #expect(await rig.sleeper.requests.next() == retryDelay)
    #expect(rig.bar.readCount == 2)

    rig.sleeper.releaseNewest()

    #expect(isRead(await rig.passes.next()))
    await settle()
    #expect(rig.bar.readCount == 3)
    #expect(rig.sleeper.requestCount == 1)
}

// Catches a bar that stays unreadable being polled. Mutation: make `ScanFlow.retriesUnread` ignore `previousRead`,
// or delete `state.lastPassRead = pass.drawn != nil` in `drain()`.
@Test(.timeLimit(.minutes(1))) func anUnreadPassAfterAnUnreadRetryGetsNoFurtherPass() async {
    let rig = Rig([.read, .unread, .unread, .unread])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))
    rig.scanner.requestScan()
    #expect(await rig.passes.next() == .unread)
    #expect(await rig.sleeper.requests.next() == retryDelay)
    rig.sleeper.releaseNewest()
    #expect(await rig.passes.next() == .unread)

    // Nothing is left to wake; a later request still scans, which marks the point by which a second retry would
    // have asked for its sleep.
    rig.sleeper.releaseAll()
    rig.scanner.requestScan()
    #expect(await rig.passes.next() == .unread)
    await settle()

    #expect(rig.sleeper.requestCount == 1)
    #expect(rig.bar.readCount == 4)
}

// Catches a retry that fires after a revocation starting a pass, which would read the bar without Accessibility.
// Mutation: delete the `guard state.trusted` check in `trigger()`.
@Test(.timeLimit(.minutes(1))) func aRetryThatFiresAfterARevocationScansNothing() async {
    let rig = await rigWithPendingRetry()

    rig.trust.yield(false)
    #expect(await rig.passes.next() == .unread)
    rig.sleeper.releaseAll()
    await settle()

    #expect(rig.bar.readCount == 2)
}

// Catches the revocation forgetting that the bar was readable, which would deny the first pass after the grant
// its retry. Mutation: set `state.lastPassRead = false` on a revocation in `trustChanged`.
@Test(.timeLimit(.minutes(1))) func anUnreadFirstPassAfterARegrantGetsItsOneRetry() async {
    let rig = Rig([.read, .unread, .read])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))
    rig.trust.yield(false)
    #expect(await rig.passes.next() == .unread)
    rig.trust.yield(true)
    #expect(await rig.passes.next() == .unread)
    #expect(await rig.sleeper.requests.next() == retryDelay)

    rig.sleeper.releaseNewest()

    #expect(isRead(await rig.passes.next()))
    await settle()
    #expect(rig.sleeper.requestCount == 1)
    #expect(rig.bar.readCount == 3)
}

// Catches a retry that outlives its session. Mutation: delete `unreadRetry.stop()` from `stop()`.
@Test(.timeLimit(.minutes(1))) func stoppingTheStreamCancelsThePendingRetry() async {
    let rig = await rigWithPendingRetry()

    rig.stop()

    #expect(await rig.sleeper.cancellations.next() != nil)
    rig.sleeper.releaseAll()
    await settle()
    #expect(rig.bar.readCount == 2)
}

// Catches a change in the running apps not being followed by later passes, and a newer change not replacing the
// pending ones. Mutation: delete `followUps.restart` from the apps task in `start`.
@Test(.timeLimit(.minutes(1))) func aRunningAppsChangeSchedulesFollowUpPassesAndANewChangeRestartsThem() async {
    let rig = Rig([.read, .read, .read, .read, .read])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))

    rig.apps.yield([AppID("com.example.a")])
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.requests.next() == .seconds(1))
    rig.sleeper.releaseNewest()
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.requests.next() == .seconds(2))

    // The second change drops the schedule that waits for 3 s and starts again at 1 s.
    rig.apps.yield([AppID("com.example.b")])
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.cancellations.next() != nil)
    #expect(await rig.sleeper.requests.next() == .seconds(1))
    rig.sleeper.releaseNewest()
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.requests.next() == .seconds(2))
    #expect(rig.bar.readCount == 5)
}

// Catches a concealment change being read only at once: macOS reflows the bar after the activation, so a module that
// comes back would stay out of Layout until some other event. Mutation: delete `concealmentFollowUp.restart` from
// `concealmentChanged()`.
@Test(.timeLimit(.minutes(1))) func aConcealmentChangeScansAtOnceAndOnceMoreASecondLater() async {
    let rig = Rig([.read, .read, .read])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))

    rig.scanner.concealmentChanged()
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.requests.next() == .seconds(1))
    rig.sleeper.releaseNewest()
    #expect(isRead(await rig.passes.next()))
    await settle()
    #expect(rig.bar.readCount == 3)
    #expect(rig.sleeper.requestCount == 1)
}

// Catches the concealment's follow-up pass outliving its session. Mutation: delete `concealmentFollowUp.stop()` from
// `stop()`.
@Test(.timeLimit(.minutes(1))) func stoppingTheStreamEndsThePendingConcealmentFollowUp() async {
    let rig = Rig([.read, .read])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))
    rig.scanner.concealmentChanged()
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.requests.next() == .seconds(1))

    rig.stop()

    #expect(await rig.sleeper.cancellations.next() != nil)
    rig.sleeper.releaseAll()
    await settle()
    #expect(rig.bar.readCount == 2)
}

// Catches follow-up passes that outlive their session. Mutation: delete `followUps.stop()` from `stop()`.
@Test(.timeLimit(.minutes(1))) func stoppingTheStreamEndsThePendingFollowUps() async {
    let rig = Rig([.read, .read])
    rig.trust.yield(true)
    #expect(isRead(await rig.passes.next()))
    rig.apps.yield([AppID("com.example.a")])
    #expect(isRead(await rig.passes.next()))
    #expect(await rig.sleeper.requests.next() == .seconds(1))

    rig.stop()

    #expect(await rig.sleeper.cancellations.next() != nil)
    rig.sleeper.releaseAll()
    await settle()
    #expect(rig.bar.readCount == 2)
}

// Catches an attach to MenuBarAgent from a pass that finishes after the revocation, which fails for want of
// Accessibility rather than for anything the agent did. Mutation: delete the `mayAttach` guard in `observeAgent`.
@Test(.timeLimit(.minutes(1))) func noAttachIsAttemptedAfterARevocationEvenFromAPassThatFinishesLater() async {
    let rig = Rig([.held, .read], agentPID: 7, observableAgent: true)
    rig.trust.yield(true)
    #expect(await rig.agent.attaches.next() != nil)
    #expect(await rig.bar.started.next() != nil)

    rig.trust.yield(false)
    #expect(await rig.passes.next() == .unread)
    rig.bar.release()
    #expect(await rig.barRead.next() != nil)
    await settle()
    #expect(rig.agent.attachCount == 1)

    rig.trust.yield(true)
    #expect(await rig.agent.attaches.next() != nil)
    #expect(isRead(await rig.passes.next()))
    #expect(rig.agent.attachCount == 2)
}

// Catches an observer that is left running after the revocation, or one that is not attached again after the
// grant. Mutation: delete `invalidate?()` after the lock in `trustChanged`.
@Test(.timeLimit(.minutes(1))) func aRevocationInvalidatesTheAgentObserverAndAGrantAttachesAgain() async {
    let rig = Rig([.read, .read], agentPID: 7, observableAgent: true)
    rig.trust.yield(true)
    #expect(await rig.agent.attaches.next() != nil)
    #expect(isRead(await rig.passes.next()))

    rig.trust.yield(false)
    #expect(await rig.passes.next() == .unread)
    #expect(await rig.agent.invalidations.next() != nil)

    rig.trust.yield(true)
    #expect(await rig.agent.attaches.next() != nil)
    #expect(isRead(await rig.passes.next()))
    await settle()
    #expect(rig.agent.attachCount == 2)
}

// Catches an agent observer that outlives its session. Mutation: delete `invalidate?()` from `stop()`.
@Test(.timeLimit(.minutes(1))) func stoppingTheStreamInvalidatesTheAgentObserver() async {
    let rig = Rig([.read], agentPID: 7, observableAgent: true)
    rig.trust.yield(true)
    #expect(await rig.agent.attaches.next() != nil)
    #expect(isRead(await rig.passes.next()))

    rig.stop()

    #expect(await rig.agent.invalidations.next() != nil)
}
