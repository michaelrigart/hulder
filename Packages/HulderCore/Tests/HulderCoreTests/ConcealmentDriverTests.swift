import Foundation
import Testing
@testable import HulderCore

@MainActor
struct ConcealmentDriverTests {
    typealias Call = FakeConcealmentBackend.Call

    private let own = AppID("com.michaelrigart.hulder")
    private let a = AppID("com.example.a")
    private let b = AppID("com.example.b")

    private final class Outcomes {
        var values: [ApplyOutcome] = []
    }

    private struct Fixture {
        let backend: FakeConcealmentBackend
        let controller: ConcealmentController
        let driver: ConcealmentDriver
        let outcomes: Outcomes
    }

    private var layout: Layout {
        var layout = Layout()
        let now = Date(timeIntervalSince1970: 0)
        _ = layout.recordSighting(a, name: "a", at: now)
        _ = layout.recordSighting(b, name: "b", at: now)
        layout.assign(b, to: .hidden)
        return layout
    }

    private var onlyA: Concealment { .allow(AllowList(apps: [a, own])) }
    private var aAndB: Concealment { .allow(AllowList(apps: [a, b, own])) }

    private func make(script: [UInt64: FakeConcealmentBackend.Behaviour] = [:]) -> Fixture {
        let backend = FakeConcealmentBackend(script: script)
        let controller = ConcealmentController(backend: backend, clock: ManualClock())
        let outcomes = Outcomes()
        let driver = ConcealmentDriver(controller: controller, own: own) { outcomes.values.append($0) }
        return Fixture(backend: backend, controller: controller, driver: driver, outcomes: outcomes)
    }

    @Test func driverAppliesOnlyChangedPlans() async throws {
        let f = make()

        f.driver.update(layout: layout, state: .hidden, running: [a, b])
        try #require(await waitUntil { f.outcomes.values.count == 1 })
        f.driver.update(layout: layout)
        // A plan that ends the concealment is sent after the repeat; if the repeat had been sent too,
        // it would have produced an `unchanged` outcome before it.
        f.driver.update(state: .revealedAll)
        try #require(await waitUntil { f.outcomes.values.count >= 2 })

        #expect(f.outcomes.values == [.applied, .applied])
        let log = await f.backend.log
        #expect(log.filter { if case .prepare = $0 { true } else { false } }.count == 1)
    }

    @Test func driverAppliesWithoutAnyInventory() async throws {
        let f = make()

        f.driver.update(layout: layout, state: .hidden, running: [a, b])

        try #require(await waitUntil { await f.controller.current == onlyA })
        #expect(await f.backend.activeTokens == [1])
    }

    @Test func nothingIsAppliedBeforeAnythingNeedsConcealing() async throws {
        let f = make()

        f.driver.update(running: [a, b])
        try #require(await waitUntil { f.outcomes.values.count == 1 })

        #expect(f.outcomes.values == [.unchanged])
        #expect(await f.backend.log.isEmpty)
    }

    @Test func returningToTheAppliedPlanWhileAnotherIsPendingWins() async throws {
        let f = make(script: [2: .hang])

        f.driver.update(layout: layout, state: .hidden, running: [a, b])
        try #require(await waitUntil { f.outcomes.values.count == 1 })
        f.driver.update(state: .revealed)
        try #require(await waitUntil { await f.backend.log.contains(.activate(2)) })
        f.driver.update(state: .hidden)
        try #require(await waitUntil { await f.controller.queuedRequests == 1 })
        await f.backend.complete(2)

        try #require(await waitUntil { f.outcomes.values.count == 2 })
        #expect(await f.backend.log.contains(.invalidate(2)))
        #expect(await f.controller.current == onlyA)
        #expect(await f.backend.activeTokens == [1])
        // The superseded request for the middle plan is not reported.
        #expect(f.outcomes.values == [.applied, .unchanged])
    }

    @Test func failedApplyIsRetriedOnTheNextUpdate() async throws {
        let f = make(script: [1: .fail])

        f.driver.update(layout: layout, state: .hidden, running: [a, b])
        try #require(await waitUntil { f.outcomes.values.count == 1 })
        #expect(f.outcomes.values == [.failed(.rejected)])

        f.driver.update(layout: layout)

        try #require(await waitUntil { f.outcomes.values.count == 2 })
        #expect(f.outcomes.values == [.failed(.rejected), .applied])
        #expect(await f.backend.log.contains(.prepare(2, [a, own])))
        #expect(await f.controller.current == onlyA)
    }

    @Test func aFailureOfAnOlderRequestDoesNotForgetTheNewerPlan() async throws {
        let f = make(script: [1: .hang])

        f.driver.update(layout: layout, state: .hidden, running: [a, b])
        try #require(await waitUntil { await f.backend.log.contains(.activate(1)) })
        f.driver.update(state: .revealed)
        try #require(await waitUntil { await f.controller.queuedRequests == 1 })
        await f.backend.fail(1)
        try #require(await waitUntil { f.outcomes.values.count == 1 })
        #expect(f.outcomes.values == [.applied])
        #expect(await f.controller.current == aAndB)

        f.driver.update(layout: layout)
        f.driver.update(state: .revealedAll)

        try #require(await waitUntil { f.outcomes.values.count >= 2 })
        #expect(f.outcomes.values == [.applied, .applied])
    }

    @Test func releaseAllEndsTheConcealment() async throws {
        let f = make()
        f.driver.update(layout: layout, state: .hidden, running: [a, b])
        try #require(await waitUntil { await f.controller.current == onlyA })

        await f.driver.releaseAll()

        #expect(await f.controller.current == .none)
        #expect(await f.backend.activeTokens.isEmpty)
    }
}
