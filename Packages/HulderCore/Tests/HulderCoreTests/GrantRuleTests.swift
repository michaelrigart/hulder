import Testing
@testable import HulderCore

struct GrantRuleTests {
    @Test func aStartWithTheGrantUsesIt() {
        var rule = GrantRule()
        #expect(rule.read(granted: true) == .use(true))
    }

    @Test func aStartWithoutTheGrantUsesNotGranted() {
        var rule = GrantRule()
        #expect(rule.read(granted: false) == .use(false))
    }

    @Test func aRepeatedReadingDoesNothing() {
        var granted = GrantRule()
        _ = granted.read(granted: true)
        #expect(granted.read(granted: true) == .nothing)

        var missing = GrantRule()
        _ = missing.read(granted: false)
        #expect(missing.read(granted: false) == .nothing)
    }

    @Test func theFirstGrantInAProcessThatRanWithoutItRelaunches() {
        var rule = GrantRule()
        _ = rule.read(granted: false)
        #expect(rule.read(granted: true) == .relaunch)
    }

    @Test func aRevocationThenAGrantRelaunches() {
        var rule = GrantRule()
        _ = rule.read(granted: true)
        #expect(rule.read(granted: false) == .use(false))
        #expect(rule.read(granted: true) == .relaunch)
    }

    @Test func everyReadingWhileARelaunchIsUnderWayDoesNothing() {
        var rule = GrantRule()
        _ = rule.read(granted: false)
        _ = rule.read(granted: true)
        #expect(rule.read(granted: true) == .nothing)
        #expect(rule.read(granted: false) == .nothing)
        #expect(rule.relaunchAttempted(started: true) == .nothing)
        #expect(rule.read(granted: true) == .nothing)
    }

    @Test func aRelaunchThatCouldNotStartUsesTheGrantHere() {
        var rule = GrantRule()
        _ = rule.read(granted: false)
        _ = rule.read(granted: true)
        #expect(rule.relaunchAttempted(started: false) == .use(true))
    }

    @Test func aFailedRelaunchIsNeverTriedAgain() {
        var rule = GrantRule()
        _ = rule.read(granted: false)
        _ = rule.read(granted: true)
        _ = rule.relaunchAttempted(started: false)
        #expect(rule.read(granted: false) == .use(false))
        #expect(rule.read(granted: true) == .use(true))
    }

    @Test func aRelaunchResultWithNoRelaunchDoesNothing() {
        var rule = GrantRule()
        _ = rule.read(granted: true)
        #expect(rule.relaunchAttempted(started: false) == .nothing)
    }
}
