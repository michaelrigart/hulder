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

    let wifi = SystemItemID(moduleName: "WiFi")
    let systemUIServer = AppID("com.apple.systemuiserver")
    let textInput = AppID("com.apple.TextInputMenuAgent")
    let menuBarAgent = AppID("com.apple.MenuBarAgent")
    let controlCenter = AppID("com.apple.controlcenter")

    func allow(_ apps: Set<AppID>, hiding hiddenSystemItems: Set<SystemItemID> = []) -> Concealment {
        .allow(AllowList(apps: apps.union([menuBarAgent, controlCenter]), hiddenSystemItems: hiddenSystemItems))
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

    @Test func nothingAssignedAndVisibleDefaultHoldsNothing() {
        let plan = ConcealmentPlanner.plan(layout: Layout(), state: .hidden, running: [a, e], own: own)
        #expect(plan == .none)
    }

    @Test func hiddenAppLeavesSystemItemsAlone() {
        let plan = ConcealmentPlanner.plan(layout: layout(), state: .hidden, running: [a, b], own: own)
        guard case .allow(let list) = plan else { Issue.record("expected an allowlist"); return }
        #expect(list.hiddenSystemItems.isEmpty)
    }

    @Test func appleOwnersStayAllowedUntilAssigned() {
        let plan = ConcealmentPlanner.plan(
            layout: layout(defaultSection: .hidden), state: .hidden,
            running: [a, e, systemUIServer, textInput], own: own)
        #expect(plan == allow([a, d, systemUIServer, textInput, own]))
    }

    @Test func menuBarAgentAndControlCenterAreAlwaysAllowed() {
        var assigned = layout(defaultSection: .alwaysHidden)
        for owner in [menuBarAgent, controlCenter] {
            _ = assigned.recordSighting(owner, name: owner.bundleID, at: Date(timeIntervalSince1970: 0))
            assigned.assign(owner, to: .alwaysHidden)
        }
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .hidden, running: [b, menuBarAgent, controlCenter], own: own)
        #expect(plan == allow([a, d, own]))
    }

    @Test func assignedAppleOwnerIsConcealedLikeAnApp() {
        var assigned = layout()
        _ = assigned.recordSighting(systemUIServer, name: "SystemUIServer", at: Date(timeIntervalSince1970: 0))
        assigned.assign(systemUIServer, to: .hidden)
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .hidden, running: [a, systemUIServer], own: own)
        #expect(plan == allow([a, d, own]))
    }

    @Test func hiddenModuleIsHiddenWhileTheBarIsHidden() {
        var assigned = Layout()
        assigned.assign(wifi, to: .hidden)
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .hidden, running: [a], own: own)
        #expect(plan == allow([a, own], hiding: [wifi]))
    }

    @Test func hiddenModuleKeepsTheAssertionWithoutReflowWhileRevealed() {
        var assigned = Layout()
        assigned.assign(wifi, to: .hidden)
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .revealed, running: [a], own: own)
        #expect(plan == allow([a, own]))
    }

    @Test func alwaysHiddenModuleStaysHiddenWhileRevealed() {
        var assigned = Layout()
        assigned.assign(wifi, to: .alwaysHidden)
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .revealed, running: [a], own: own)
        #expect(plan == allow([a, own], hiding: [wifi]))
    }

    @Test func visibleModuleHoldsNothing() {
        var assigned = Layout()
        assigned.assign(wifi, to: .visible)
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .hidden, running: [a], own: own)
        #expect(plan == .none)
    }

    @Test func revealedAllDropsModuleAssertion() {
        var assigned = Layout()
        assigned.assign(wifi, to: .alwaysHidden)
        let plan = ConcealmentPlanner.plan(layout: assigned, state: .revealedAll, running: [a], own: own)
        #expect(plan == .none)
    }
}
