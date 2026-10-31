import Foundation
import Testing
@testable import HulderCore

struct ConcealmentPlannerTests {
    let own = AppID("com.michaelrigart.hulder")
    let a = AppID("com.example.a")
    let b = AppID("com.example.b")
    let c = AppID("com.example.c")
    let d = AppID("com.example.d")
    let e = AppID("com.example.e")

    func layout(defaultSection: Section = .visible) -> Layout {
        var layout = Layout()
        let now = Date(timeIntervalSince1970: 0)
        for (app, section) in [(a, Section.visible), (b, .hidden), (c, .alwaysHidden), (d, .visible)] {
            _ = layout.recordSighting(app, name: app.bundleID, at: now)
            layout.assign(app, to: section)
        }
        layout.defaultSection = defaultSection
        return layout
    }

    func allow(_ apps: Set<AppID>) -> Concealment {
        .allow(AllowList(apps: apps, keepsAllSystemItems: true))
    }

    @Test func hiddenStateAllowsVisibleKnownAndUnknown() {
        let plan = ConcealmentPlanner.plan(layout: layout(), state: .hidden, running: [a, b, c, e], own: own)
        #expect(plan == allow([a, d, e, own]))
    }

    @Test func revealedStateAlsoAllowsHidden() {
        let plan = ConcealmentPlanner.plan(layout: layout(), state: .revealed, running: [a, b, c, e], own: own)
        #expect(plan == allow([a, b, d, e, own]))
    }

    @Test func revealedAllHoldsNothing() {
        let plan = ConcealmentPlanner.plan(layout: layout(), state: .revealedAll, running: [a, b, c, e], own: own)
        #expect(plan == .none)
    }

    @Test func noHiddenAppRunningHoldsNothing() {
        for state in [RevealState.hidden, .revealed] {
            let plan = ConcealmentPlanner.plan(layout: layout(), state: state, running: [a, e], own: own)
            #expect(plan == .none)
        }
    }

    @Test func revealedKeepsAssertionWithoutAlwaysHiddenRunning() {
        let plan = ConcealmentPlanner.plan(layout: layout(), state: .revealed, running: [a, b], own: own)
        #expect(plan == allow([a, b, d, own]))
    }

    @Test func unknownAppsFollowDefaultSection() {
        let plan = ConcealmentPlanner.plan(layout: layout(defaultSection: .hidden), state: .hidden, running: [a, e], own: own)
        #expect(plan == allow([a, d, own]))
    }

    @Test func ownAppIsNeverConcealedOrCounted() {
        var hiddenOwn = layout()
        hiddenOwn.defaultSection = .hidden
        let plan = ConcealmentPlanner.plan(layout: hiddenOwn, state: .hidden, running: [own], own: own)
        #expect(plan == .none)
    }
}
