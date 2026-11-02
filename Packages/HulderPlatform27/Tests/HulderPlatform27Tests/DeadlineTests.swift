import Synchronization
import Testing
@testable import HulderPlatform27

/// Hands a value to a call that is waiting for it.
private final class Latch: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?> = Mutex(nil)
    private let released = Mutex(false)

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = released.withLock { $0 }
            if ready { continuation.resume() } else { self.continuation.withLock { $0 = continuation } }
        }
    }

    func release() {
        released.withLock { $0 = true }
        continuation.withLock { $0.take() }?.resume()
    }
}

@Test(.timeLimit(.minutes(1))) func aCallThatAnswersInTimeReturnsItsValueAndNeitherExpiresNorIsLate() async throws {
    let events = Mutex(0)

    let value = try await Deadline.run(
        within: .seconds(30), { 7 }, expired: { events.withLock { $0 += 1 } }, late: { _ in events.withLock { $0 += 1 } })

    #expect(value == 7)
    #expect(events.withLock { $0 } == 0)
}

@Test(.timeLimit(.minutes(1))) func aCallThatMissesItsDeadlineExpiresFirstAndThenHandsOnItsLateResult() async throws {
    let latch = Latch()
    let order = Mutex<[String]>([])
    let (results, late) = AsyncStream.makeStream(of: Int?.self)

    await #expect(throws: Deadline.Expired.self) {
        try await Deadline.run(
            within: .milliseconds(20), { await latch.wait(); return 9 },
            expired: { order.withLock { $0.append("expired") } },
            late: { result in
                order.withLock { $0.append("late") }
                late.yield(try? result.get())
            })
    }
    #expect(order.withLock { $0 } == ["expired"])
    latch.release()

    var iterator = results.makeAsyncIterator()
    #expect(await iterator.next() == .some(9))
    #expect(order.withLock { $0 } == ["expired", "late"])
}

@Test(.timeLimit(.minutes(1))) func aCallThatFailsInTimeRethrowsItsError() async {
    struct Failure: Error {}

    await #expect(throws: Failure.self) { try await Deadline.run(within: .seconds(30), { throw Failure() }) as Int }
}
