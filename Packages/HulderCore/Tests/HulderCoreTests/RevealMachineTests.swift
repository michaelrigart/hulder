import Testing
@testable import HulderCore

struct RevealMachineTests {
    private func machine(autoRehide: Duration? = .seconds(10)) -> RevealMachine {
        RevealMachine(autoRehide: autoRehide)
    }

    @Test func clickRevealsAndSchedulesRehide() {
        var m = machine()
        let effect = m.handle(.toggle)
        #expect(m.state == .revealed)
        #expect(effect == .scheduleRehide(token: 1, after: .seconds(10)))
    }

    @Test func matchingDeadlineHides() {
        var m = machine()
        _ = m.handle(.toggle)
        let effect = m.handle(.rehideDeadline(1))
        #expect(m.state == .hidden)
        #expect(effect == nil)
    }

    @Test func staleDeadlineIsIgnored() {
        var m = machine()
        _ = m.handle(.toggle)
        _ = m.handle(.toggle)
        _ = m.handle(.toggle)
        _ = m.handle(.rehideDeadline(1))
        #expect(m.state == .revealed)
        #expect(m.pendingRehide == 2)
    }

    @Test func menuOpenDefersRehide() {
        var m = machine()
        _ = m.handle(.toggle)
        #expect(m.handle(.menuOpened) == .cancelRehide)
        _ = m.handle(.rehideDeadline(1))
        #expect(m.state == .revealed)
        #expect(m.handle(.menuClosed) == .scheduleRehide(token: 2, after: .seconds(10)))
        _ = m.handle(.rehideDeadline(2))
        #expect(m.state == .hidden)
    }

    @Test func optionClickRevealsAllThenHides() {
        var m = machine()
        _ = m.handle(.toggleAll)
        #expect(m.state == .revealedAll)
        _ = m.handle(.toggleAll)
        #expect(m.state == .hidden)
    }

    @Test func clickFromRevealedAllHides() {
        var m = machine()
        _ = m.handle(.toggleAll)
        let effect = m.handle(.toggle)
        #expect(m.state == .hidden)
        #expect(effect == .cancelRehide)
    }

    @Test func lockHides() {
        var m = machine()
        _ = m.handle(.toggle)
        let effect = m.handle(.lockedOrAsleep)
        #expect(m.state == .hidden)
        #expect(effect == .cancelRehide)
    }

    @Test func menuClosedWhileHiddenClearsTheFlag() {
        var m = machine()
        _ = m.handle(.menuOpened)
        _ = m.handle(.menuClosed)
        let effect = m.handle(.toggle)
        #expect(m.isMenuOpen == false)
        #expect(effect == .scheduleRehide(token: 1, after: .seconds(10)))
    }

    @Test func noAutomaticRehideWithoutDelay() {
        var m = machine(autoRehide: nil)
        #expect(m.handle(.toggle) == nil)
        #expect(m.handle(.menuClosed) == nil)
    }

    @Test func fullTrackingAfterAPartialEpisodeSchedulesTheRehideAgain() {
        var m = machine()
        _ = m.handle(.toggle)
        #expect(m.setAutoRehide(nil) == .cancelRehide)

        let effect = m.setAutoRehide(.seconds(10))

        #expect(effect == .scheduleRehide(token: 2, after: .seconds(10)))
        #expect(m.handle(.rehideDeadline(1)) == nil)
        #expect(m.state == .revealed)
        #expect(m.handle(.rehideDeadline(2)) == nil)
        #expect(m.state == .hidden)
    }

    @Test func turningAutomaticHidingOnWhileRevealedSchedulesARehide() {
        for reveal in [RevealInput.toggle, .toggleAll] {
            var m = machine(autoRehide: nil)
            _ = m.handle(reveal)

            #expect(m.setAutoRehide(.seconds(10)) == .scheduleRehide(token: 1, after: .seconds(10)))
            #expect(m.pendingRehide == 1)
        }
    }

    @Test func aRepeatedDelayDoesNotPushBackAPendingRehide() {
        var m = machine()
        _ = m.handle(.toggle)

        #expect(m.setAutoRehide(.seconds(10)) == nil)
        #expect(m.setAutoRehide(.seconds(30)) == nil)

        #expect(m.pendingRehide == 1)
        #expect(m.autoRehide == .seconds(30))
        #expect(m.handle(.rehideDeadline(1)) == nil)
        #expect(m.state == .hidden)
    }

    @Test func noRehideIsScheduledWhileAMenuIsOpenOrHidden() {
        var hidden = machine(autoRehide: nil)
        #expect(hidden.setAutoRehide(.seconds(10)) == nil)
        #expect(hidden.pendingRehide == nil)

        var open = machine(autoRehide: nil)
        _ = open.handle(.toggle)
        _ = open.handle(.menuOpened)
        #expect(open.setAutoRehide(.seconds(10)) == nil)
        #expect(open.pendingRehide == nil)
        // Closing the menu is what starts the delay.
        #expect(open.handle(.menuClosed) == .scheduleRehide(token: 1, after: .seconds(10)))
    }

    @Test func partialTrackingDisablesAutoRehide() {
        #expect(RevealPolicy.autoRehide(delay: .seconds10, tracking: .partial) == nil)
        #expect(RevealPolicy.autoRehide(delay: .seconds10, tracking: .full) == .seconds(10))
        #expect(RevealPolicy.autoRehide(delay: .never, tracking: .full) == nil)
    }
}
