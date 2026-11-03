import Foundation
import Testing
import HulderCore
@testable import HulderPlatform27

@Test func translatesAllowList() {
    let list = AllowList(apps: [AppID("com.example.b"), AppID("com.example.a")])
    let arguments = AllowListTranslation.arguments(for: list)
    #expect(arguments.bundleIDs == ["com.example.a", "com.example.b"])
    #expect(arguments.systemItems == Array(0...127))
}

// Catches a translation that ignores the hidden modules: they would stay on the bar.
@Test func hiddenModulesLeaveTheirNumbersOutOfTheSystemItems() {
    let apps: Set<AppID> = [AppID("com.example.a")]
    #expect(AllowListTranslation.arguments(for: AllowList(apps: apps)).systemItems == Array(0...127))

    let wifi = AllowListTranslation.arguments(for: AllowList(apps: apps, hiddenSystemItems: [SystemItemID(moduleName: "WiFi")]))
    #expect(wifi.systemItems == Array(0...127).filter { $0 != 6 })

    let two = AllowListTranslation.arguments(
        for: AllowList(apps: apps, hiddenSystemItems: [SystemItemID(moduleName: "Battery"), SystemItemID(moduleName: "BentoBox")]))
    #expect(two.systemItems == Array(0...127).filter { $0 != 0 && $0 != 8 })
}

// Catches a module without a number being guessed: nothing is removed for it.
@Test func aModuleTheTableDoesNotKnowRemovesNothing() {
    let list = AllowList(apps: [], hiddenSystemItems: [SystemItemID(moduleName: "Sound")])
    #expect(AllowListTranslation.arguments(for: list).systemItems == Array(0...127))
}

@Test func theTableMapsIdentifiersToModulesAndNumbers() throws {
    let wifi = try #require(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.wifi"))
    #expect(wifi.id == SystemItemID(moduleName: "WiFi") && wifi.number == 6 && wifi.orderName == "WiFi")
    let center = try #require(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.CONTROLCENTER"))
    #expect(center.id == SystemItemID(moduleName: "BentoBox") && center.number == 8 && center.orderName == "BentoBox")
    #expect(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.battery")?.number == 0)
    #expect(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.clock")?.number == 2)
    #expect(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.focusmode") == nil)
    #expect(SystemItemTable27.entry(forIdentifier: nil) == nil)
    #expect(SystemItemTable27.number(for: SystemItemID(moduleName: "Clock")) == 2)
    #expect(SystemItemTable27.number(for: SystemItemID(moduleName: "Sound")) == nil)
}

/// v1's planner rule, frozen: the allowlist with nothing Apple assigned and Visible as the default section.
private func v1Arguments(layout: Layout, state: RevealState, running: Set<AppID>, own: AppID) -> (bundleIDs: [String], systemItems: [Int])? {
    if state == .revealedAll { return nil }
    let others = running.subtracting([own])
    if !others.contains(where: { layout.effectiveSection(of: $0) != .visible }) { return nil }
    var allowed = others.filter { !state.conceals(layout.effectiveSection(of: $0)) }
    for (app, known) in layout.apps where known.section == .visible { allowed.insert(app) }
    allowed.insert(own)
    return (allowed.map(\.bundleID).sorted(), Array(0...127))
}

// Catches the planner allowlisting MenuBarAgent or Control Center when they are not running: the bundle identifiers
// would differ from v1's for a user who never assigns an Apple item.
@Test func theArgumentsMatchV1WhenNothingAppleIsAssigned() {
    let own = AppID("com.michaelrigart.hulder")
    let (a, b, c) = (AppID("com.example.a"), AppID("com.example.b"), AppID("com.example.c"))
    let (agent, center) = (AppID("com.apple.MenuBarAgent"), AppID("com.apple.controlcenter"))
    let (uiServer, textInput) = (AppID("com.apple.systemuiserver"), AppID("com.apple.TextInputMenuAgent"))

    var layout = Layout()
    for (app, section) in [(a, Section.visible), (b, .hidden), (c, .alwaysHidden)] {
        _ = layout.recordSighting(app, name: app.bundleID, at: Date(timeIntervalSince1970: 0))
        layout.assign(app, to: section)
    }
    let runningSets: [Set<AppID>] = [
        [b], [a, b], [a, b, c], [b, own],
        [b, agent], [b, center], [b, agent, center], [a, c, agent, center, uiServer, textInput], [b, uiServer],
    ]
    var compared = 0
    for state in [RevealState.hidden, .revealed, .revealedAll] {
        for running in runningSets {
            let plan = ConcealmentPlanner.plan(layout: layout, state: state, running: running, own: own)
            let expected = v1Arguments(layout: layout, state: state, running: running, own: own)
            switch plan {
            case .none:
                #expect(expected == nil, "\(state) \(running.map(\.bundleID).sorted())")
            case .allow(let list):
                let arguments = AllowListTranslation.arguments(for: list)
                #expect(arguments.bundleIDs == expected?.bundleIDs, "\(state) \(running.map(\.bundleID).sorted())")
                #expect(arguments.systemItems == expected?.systemItems)
                compared += 1
            }
        }
    }
    #expect(compared > 0)
}
