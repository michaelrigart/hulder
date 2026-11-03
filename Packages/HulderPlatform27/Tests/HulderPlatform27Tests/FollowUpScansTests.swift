import Synchronization
import Testing
@testable import HulderPlatform27

/// A clock that only moves when the test says so. `requests` yields each duration a schedule asks to sleep, after
/// its gate is registered, so a test that has seen the request can release it.
private final class FakeSleeper: Sendable {
    let requests: AsyncStream<Duration>
    private let requested: AsyncStream<Duration>.Continuation
    private let gates = Mutex<[AsyncStream<Void>.Continuation]>([])

    init() { (requests, requested) = AsyncStream.makeStream() }

    func sleep(_ duration: Duration) async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        gates.withLock { $0.append(release) }
        requested.yield(duration)
        for await _ in gate { break }
        try Task.checkCancellation()
    }

    /// Wakes the sleep that was requested last.
    func releaseNewest() { gates.withLock { $0.popLast() }?.yield() }

    /// Wakes every pending sleep, oldest first, as if the time they wait for had passed.
    func releaseAll() { gates.withLock { let all = $0; $0 = []; return all }.forEach { $0.yield() } }
}

/// Records which schedule fired.
private final class Fires: Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let log = Mutex<[String]>([])

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func fire(_ name: String) {
        log.withLock { $0.append(name) }
        continuation.yield(name)
    }

    func count(_ name: String) -> Int { log.withLock { $0.filter { $0 == name }.count } }
}

@Test(.timeLimit(.minutes(1))) func aChangeIsFollowedByPassesAtTheOffsets() async {
    let sleeper = FakeSleeper()
    let fires = Fires()
    var requests = sleeper.requests.makeAsyncIterator()
    var fired = fires.stream.makeAsyncIterator()
    let followUps = FollowUpScans(offsets: [.seconds(1), .seconds(3), .seconds(10), .seconds(30)], sleep: sleeper.sleep)

    followUps.restart { fires.fire("change") }

    // Each sleep is the gap since the last pass, so the passes land at 1, 3, 10 and 30 s.
    var slept: [Duration] = []
    for _ in 0..<4 {
        slept.append(await requests.next()!)
        #expect(fires.count("change") == slept.count - 1)
        sleeper.releaseNewest()
        _ = await fired.next()
    }
    #expect(slept == [.seconds(1), .seconds(2), .seconds(7), .seconds(20)])
    #expect(fires.count("change") == 4)
}

@Test func theOffsetsAreOneToThirtySeconds() {
    #expect(FollowUpScans.offsets == [.seconds(1), .seconds(3), .seconds(10), .seconds(30)])
}

@Test(.timeLimit(.minutes(1))) func aSecondChangeRestartsTheScheduleAndTheFirstOneFiresNoMore() async {
    let sleeper = FakeSleeper()
    let fires = Fires()
    var requests = sleeper.requests.makeAsyncIterator()
    var fired = fires.stream.makeAsyncIterator()
    let followUps = FollowUpScans(offsets: [.seconds(1), .seconds(3), .seconds(10), .seconds(30)], sleep: sleeper.sleep)
    followUps.restart { fires.fire("first") }
    _ = await requests.next()
    sleeper.releaseNewest()
    _ = await fired.next()
    _ = await requests.next()

    followUps.restart { fires.fire("second") }
    #expect(await requests.next() == .seconds(1))
    // Everything that is pending wakes, the first schedule's sleep included.
    for _ in 0..<4 {
        sleeper.releaseAll()
        _ = await fired.next()
        if fires.count("second") < 4 { _ = await requests.next() }
    }

    #expect(fires.count("second") == 4)
    #expect(fires.count("first") == 1)
}

@Test(.timeLimit(.minutes(1))) func stoppingCancelsThePendingFollowUpsForGood() async {
    let sleeper = FakeSleeper()
    let fires = Fires()
    var requests = sleeper.requests.makeAsyncIterator()
    var fired = fires.stream.makeAsyncIterator()
    let followUps = FollowUpScans(offsets: [.seconds(1), .seconds(3)], sleep: sleeper.sleep)
    followUps.restart { fires.fire("stopped") }
    _ = await requests.next()

    followUps.stop()
    followUps.restart { fires.fire("stopped") }
    // A schedule that nothing stopped, asking for a distinct 5 s, marks the point by which a surviving one would
    // have requested its sleep too.
    let marker = FollowUpScans(offsets: [.seconds(5)], sleep: sleeper.sleep)
    marker.restart { fires.fire("marker") }
    while await requests.next() != .seconds(5) {}
    sleeper.releaseAll()
    _ = await fired.next()

    #expect(fires.count("stopped") == 0)
    #expect(fires.count("marker") == 1)
}

// Catches a revocation leaving a pending retry that scans after it, or one that disables every later schedule.
@Test(.timeLimit(.minutes(1))) func cancellingDropsThePendingScheduleButNotLaterOnes() async {
    let sleeper = FakeSleeper()
    let fires = Fires()
    var requests = sleeper.requests.makeAsyncIterator()
    var fired = fires.stream.makeAsyncIterator()
    let followUps = FollowUpScans(offsets: [.milliseconds(500)], sleep: sleeper.sleep)
    followUps.restart { fires.fire("cancelled") }
    _ = await requests.next()

    followUps.cancel()
    // A schedule that nothing cancelled, asking for a distinct 5 s, marks the point by which a surviving one would
    // have fired too.
    let marker = FollowUpScans(offsets: [.seconds(5)], sleep: sleeper.sleep)
    marker.restart { fires.fire("marker") }
    while await requests.next() != .seconds(5) {}
    sleeper.releaseAll()
    _ = await fired.next()
    #expect(fires.count("cancelled") == 0)

    followUps.restart { fires.fire("later") }
    #expect(await requests.next() == .milliseconds(500))
    sleeper.releaseNewest()
    _ = await fired.next()
    #expect(fires.count("later") == 1)
}
