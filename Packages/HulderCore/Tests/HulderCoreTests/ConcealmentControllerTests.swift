import Testing
@testable import HulderCore

struct ConcealmentControllerTests {
    private let a = Concealment.allow(AllowList(apps: [AppID("com.example.a")]))
    private let b = Concealment.allow(AllowList(apps: [AppID("com.example.b")]))
    private let c = Concealment.allow(AllowList(apps: [AppID("com.example.c")]))

    private func make(
        script: [UInt64: FakeConcealmentBackend.Behaviour] = [:]
    ) -> (FakeConcealmentBackend, ManualClock, ConcealmentController) {
        let backend = FakeConcealmentBackend(script: script)
        let clock = ManualClock()
        return (backend, clock, ConcealmentController(backend: backend, clock: clock))
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    @Test func makeBeforeBreak() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(b) == .applied)

        #expect(await backend.summary == [
            "prepare(1)", "activate(1)", "prepare(2)", "activate(2)", "invalidate(1)",
        ])
        #expect(await controller.current == b)
    }

    @Test func failedActivationKeepsOld() async {
        let (backend, _, controller) = make(script: [2: .fail])

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(b) == .failed(.rejected))

        #expect(await controller.current == a)
        let log = await backend.summary
        #expect(!log.contains("invalidate(1)"))
        #expect(log.contains("invalidate(2)"))
        #expect(await backend.activeTokens == [1])
    }

    @Test func timeoutInvalidatesAtOnce() async {
        let (backend, clock, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        #expect(await waitUntil { await backend.summary.contains("activate(1)") })
        await clock.advance(by: .seconds(3))

        // The hung activation ignores cancellation; the outcome must not wait for it.
        #expect(await apply.value == .failed(.timedOut))
        #expect(await backend.summary.contains("invalidate(1)"))
        #expect(await controller.current == .none)
    }

    @Test func timeoutDoesNotFireEarly() async {
        let (backend, clock, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        #expect(await waitUntil { await backend.summary.contains("activate(1)") })
        await clock.advance(by: .seconds(2))
        let log = await backend.summary
        #expect(!log.contains("invalidate(1)"))

        await backend.complete(1)
        #expect(await apply.value == .applied)
        #expect(await controller.current == a)
    }

    @Test func lateCompletionAfterRevealAllLeavesNothingHidden() async {
        let (backend, clock, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        #expect(await waitUntil { await backend.summary.contains("activate(1)") })
        await clock.advance(by: .seconds(3))
        #expect(await apply.value == .failed(.timedOut))

        #expect(await controller.apply(.none) == .unchanged)
        await backend.complete(1)

        // Once to cut the attempt short, once more when the late completion lands.
        #expect(await waitUntil { await backend.count(of: "invalidate(1)") == 2 })
        #expect(await backend.summary.last == "invalidate(1)")
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func lateCompletionAfterRevealAllWithLiveAssertion() async {
        let (backend, clock, controller) = make(script: [2: .hang])

        #expect(await controller.apply(a) == .applied)
        let apply = Task { await controller.apply(b) }
        #expect(await waitUntil { await backend.summary.contains("activate(2)") })
        await clock.advance(by: .seconds(3))
        #expect(await apply.value == .failed(.timedOut))
        #expect(await controller.current == a)

        #expect(await controller.apply(.none) == .applied)
        await backend.complete(2)

        // Once to cut the attempt short, once more when the late completion lands.
        #expect(await waitUntil { await backend.count(of: "invalidate(2)") == 2 })
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func supersededPendingIsInvalidatedOnCompletion() async {
        let (backend, _, controller) = make(script: [1: .hang])

        let first = Task { await controller.apply(a) }
        #expect(await waitUntil { await backend.summary.contains("activate(1)") })
        let second = Task { await controller.apply(b) }
        #expect(await waitUntil { await controller.queuedRequests == 1 })
        let third = Task { await controller.apply(c) }
        #expect(await waitUntil { await controller.queuedRequests == 2 })

        await backend.complete(1)

        #expect(await first.value == .superseded)
        #expect(await second.value == .superseded)
        #expect(await third.value == .applied)
        let log = await backend.log
        #expect(log.filter { if case .prepare = $0 { true } else { false } }.count == 2)
        let summary = await backend.summary
        #expect(summary.firstIndex(of: "invalidate(1)")! < summary.firstIndex(of: "prepare(2)")!)
        #expect(await controller.current == c)
        #expect(await backend.activeTokens == [2])
    }

    @Test func unchangedIsNotReapplied() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(a) == .unchanged)

        let prepares = await backend.summary.filter { $0.hasPrefix("prepare") }
        #expect(prepares == ["prepare(1)"])
    }

    @Test func noneInvalidatesTheLiveToken() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        #expect(await controller.apply(.none) == .applied)

        #expect(await backend.summary.last == "invalidate(1)")
        #expect(await backend.activeTokens.isEmpty)
        #expect(await controller.current == .none)
    }

    @Test func prepareFailureIsReportedAndKeepsOld() async {
        let (backend, _, controller) = make()

        #expect(await controller.apply(a) == .applied)
        await backend.setFailsPrepare(true)
        let outcome = await controller.apply(b)

        #expect(outcome == .failed(.unavailable(ConcealmentController.unavailableText)))
        #expect(await controller.current == a)
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

    @Test func releaseAllInvalidatesLiveAndPending() async {
        let (backend, _, controller) = make(script: [2: .hang])

        #expect(await controller.apply(a) == .applied)
        let pending = Task { await controller.apply(b) }
        #expect(await waitUntil { await backend.summary.contains("activate(2)") })
        let queued = Task { await controller.apply(c) }
        #expect(await waitUntil { await controller.queuedRequests == 1 })

        await controller.releaseAll()

        #expect(await pending.value == .superseded)
        #expect(await queued.value == .superseded)
        let log = await backend.summary
        #expect(log.contains("invalidate(1)"))
        #expect(log.contains("invalidate(2)"))
        #expect(!log.contains("prepare(3)"))
        #expect(await controller.current == .none)
        #expect(await backend.activeTokens.isEmpty)
    }

    @Test func completionAfterReleaseNeverBecomesCurrent() async {
        let (backend, _, controller) = make(script: [1: .hang])

        let apply = Task { await controller.apply(a) }
        #expect(await waitUntil { await backend.summary.contains("activate(1)") })
        await controller.releaseAll()
        await backend.complete(1)

        #expect(await apply.value == .superseded)
        // Once to cut the attempt short, once more when the late completion lands.
        #expect(await waitUntil { await backend.count(of: "invalidate(1)") == 2 })
        #expect(await controller.current == .none)
        #expect(await backend.activeTokens.isEmpty)

        #expect(await controller.apply(b) == .superseded)
        let finalLog = await backend.summary
        #expect(!finalLog.contains("prepare(2)"))
    }
}
