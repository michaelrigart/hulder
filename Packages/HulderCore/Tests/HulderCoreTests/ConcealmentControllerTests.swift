import Testing
@testable import HulderCore

struct ConcealmentControllerTests {
    typealias Call = FakeConcealmentBackend.Call

    private static let appsA: Set<AppID> = [AppID("com.example.a")]
    private static let appsB: Set<AppID> = [AppID("com.example.b")]
    private static let appsC: Set<AppID> = [AppID("com.example.c")]

    private let a = Concealment.allow(AllowList(apps: appsA))
    private let b = Concealment.allow(AllowList(apps: appsB))
    private let c = Concealment.allow(AllowList(apps: appsC))

    private func make(
        script: [UInt64: FakeConcealmentBackend.Behaviour] = [:]
    ) -> (FakeConcealmentBackend, ManualClock, ConcealmentController) {
        let backend = FakeConcealmentBackend(script: script)
        let clock = ManualClock()
        return (backend, clock, ConcealmentController(backend: backend, clock: clock))
    }

    private func waitForLog(
        _ backend: FakeConcealmentBackend,
        count: Int
    ) async -> Bool {
        await waitUntil { await backend.log.count >= count }
    }

    @Test func makeBeforeBreak() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(b) == .applied)

        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .prepare(2, Self.appsB), .activate(2), .invalidate(1),
        ])
        #expect(await controller.current == b)
    }

    @Test func failedActivationKeepsOld() async {
        let (backend, _, controller) = make(script: [2: .fail])

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(b) == .failed(.rejected))

        #expect(await controller.current == a)
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .prepare(2, Self.appsB), .activate(2), .invalidate(2),
        ])
        #expect(await backend.activeTokens == [1])
    }

    @Test func timeoutInvalidatesAtOnce() async throws {
        let (backend, clock, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        try #require(await waitForLog(backend, count: 2))
        await clock.advance(by: .seconds(3))

        // The hung activation ignores cancellation; the outcome must not wait for it.
        #expect(await apply.value == .failed(.timedOut))
        #expect(await backend.log == [.prepare(1, Self.appsA), .activate(1), .invalidate(1)])
        #expect(await controller.current == .none)
    }

    @Test func timeoutDoesNotFireEarly() async throws {
        let (backend, clock, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        try #require(await waitForLog(backend, count: 2))
        await clock.advance(by: .seconds(2))
        #expect(await backend.log == [.prepare(1, Self.appsA), .activate(1)])

        await backend.complete(1)
        #expect(await apply.value == .applied)
        #expect(await controller.current == a)
    }

    @Test func timeoutDoesNotCancelTheActivation() async throws {
        let (backend, clock, controller) = make(script: [1: .hangObservingCancellation])

        let apply = Task { await controller.apply(a) }
        try #require(await waitForLog(backend, count: 2))
        await clock.advance(by: .seconds(3))
        #expect(await apply.value == .failed(.timedOut))

        // A cancelled activation would end at once and leave a later confirmation unwatched.
        #expect(backend.cancelledTokens.isEmpty)
        #expect(await backend.log == [.prepare(1, Self.appsA), .activate(1), .invalidate(1)])

        await backend.complete(1)
        try #require(await waitForLog(backend, count: 4))
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .invalidate(1), .invalidate(1),
        ])
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func lateCompletionAfterRevealAllLeavesNothingHidden() async throws {
        let (backend, clock, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        try #require(await waitForLog(backend, count: 2))
        await clock.advance(by: .seconds(3))
        #expect(await apply.value == .failed(.timedOut))

        #expect(await controller.apply(.none) == .unchanged)
        await backend.complete(1)

        // Once to cut the attempt short, once more when the late completion lands.
        try #require(await waitForLog(backend, count: 4))
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .invalidate(1), .invalidate(1),
        ])
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func lateCompletionAfterRevealAllWithLiveAssertion() async throws {
        let (backend, clock, controller) = make(script: [2: .hang])

        #expect(await controller.apply(a) == .applied)
        let apply = Task { await controller.apply(b) }
        try #require(await waitForLog(backend, count: 4))
        await clock.advance(by: .seconds(3))
        #expect(await apply.value == .failed(.timedOut))
        #expect(await controller.current == a)

        #expect(await controller.apply(.none) == .applied)
        await backend.complete(2)

        // Token 2 is invalidated on timeout, and again when the late completion lands.
        try #require(await waitForLog(backend, count: 7))
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .prepare(2, Self.appsB), .activate(2),
            .invalidate(2), .invalidate(1), .invalidate(2),
        ])
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func supersededPendingIsInvalidatedOnCompletion() async throws {
        let (backend, _, controller) = make(script: [1: .hang])

        let first = Task { await controller.apply(a) }
        try #require(await waitForLog(backend, count: 2))
        let second = Task { await controller.apply(b) }
        try #require(await waitUntil { await controller.queuedRequests == 1 })
        let third = Task { await controller.apply(c) }
        try #require(await waitUntil { await controller.queuedRequests == 2 })

        await backend.complete(1)

        #expect(await first.value == .superseded)
        #expect(await second.value == .superseded)
        #expect(await third.value == .applied)
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .invalidate(1), .prepare(2, Self.appsC), .activate(2),
        ])
        #expect(await controller.current == c)
        #expect(await backend.activeTokens == [2])
    }

    @Test func unchangedIsNotReapplied() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(a) == .unchanged)

        #expect(await backend.log == [.prepare(1, Self.appsA), .activate(1)])
    }

    @Test func noneInvalidatesTheLiveToken() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(.none) == .applied)

        #expect(await backend.log == [.prepare(1, Self.appsA), .activate(1), .invalidate(1)])
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func prepareFailureIsReportedAndKeepsOld() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        await backend.setPrepareError(FakeConcealmentBackend.Failure())
        let outcome = await controller.apply(b)

        #expect(outcome == .failed(.unavailable("Concealment is unavailable.")))
        #expect(await controller.current == a)
        #expect(await backend.log == [.prepare(1, Self.appsA), .activate(1)])
        #expect(await backend.activeTokens == [1])
    }

    @Test func prepareFailureWithAFixedReasonReachesTheCaller() async {
        let (backend, _, controller) = make()
        await backend.setPrepareError(ConcealmentFailure.unavailable("X missing"))

        let outcome = await controller.apply(a)

        #expect(outcome == .failed(.unavailable("X missing")))
        #expect(await backend.log.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func releaseAllInvalidatesLiveAndPending() async throws {
        let (backend, _, controller) = make(script: [2: .hang])

        #expect(await controller.apply(a) == .applied)
        let pending = Task { await controller.apply(b) }
        try #require(await waitForLog(backend, count: 4))
        let queued = Task { await controller.apply(c) }
        try #require(await waitUntil { await controller.queuedRequests == 1 })

        await controller.releaseAll()

        #expect(await pending.value == .superseded)
        #expect(await queued.value == .superseded)
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .prepare(2, Self.appsB), .activate(2),
            .invalidate(1), .invalidate(2),
        ])
        #expect(await controller.current == .none)
        #expect(await backend.activeTokens.isEmpty)
    }

    @Test func releaseAllDuringPrepareLeavesNothingCurrentOrActive() async throws {
        let (backend, _, controller) = make()
        await backend.holdNextPrepare()

        let apply = Task { await controller.apply(a) }
        try #require(await waitUntil { await backend.prepareIsHeld })
        await controller.releaseAll()
        await backend.releasePrepare()

        #expect(await apply.value == .superseded)
        #expect(await backend.log == [.prepare(1, Self.appsA), .invalidate(1)])
        #expect(await controller.current == .none)
        #expect(await backend.activeTokens.isEmpty)
    }

    @Test func completionAfterReleaseNeverBecomesCurrent() async throws {
        let (backend, _, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        try #require(await waitForLog(backend, count: 2))
        await controller.releaseAll()
        await backend.complete(1)

        #expect(await apply.value == .superseded)
        // Once by the release, once more when the late completion lands.
        try #require(await waitForLog(backend, count: 4))
        #expect(await backend.log == [
            .prepare(1, Self.appsA), .activate(1), .invalidate(1), .invalidate(1),
        ])
        #expect(await controller.current == .none)
        #expect(await backend.activeTokens.isEmpty)

        #expect(await controller.apply(b) == .superseded)
        #expect(await backend.log.count == 4)
    }
}
