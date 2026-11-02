import Testing
@testable import HulderCore

@MainActor
struct RevealControllerTests {
    @Test func rehideFiresOnTheInjectedClock() async throws {
        let clock = ManualClock()
        var changes: [RevealState] = []
        let controller = RevealController(
            machine: RevealMachine(autoRehide: .seconds(10)),
            clock: clock,
            onChange: { changes.append($0) }
        )

        controller.send(.toggle)
        await clock.advance(by: .seconds(9))
        #expect(controller.state == .revealed)

        await clock.advance(by: .seconds(1))
        try #require(await waitUntil { controller.state == .hidden })
        #expect(changes == [.revealed, .hidden])
    }

    @Test func disablingAutoRehideCancelsThePendingDeadline() async throws {
        let clock = ManualClock()
        let controller = RevealController(
            machine: RevealMachine(autoRehide: .seconds(10)),
            clock: clock,
            onChange: { _ in }
        )

        controller.send(.toggle)
        controller.setAutoRehide(nil)
        await clock.advance(by: .seconds(11))

        #expect(controller.state == .revealed)
        #expect(clock.sleeperCount == 0)
    }
}
