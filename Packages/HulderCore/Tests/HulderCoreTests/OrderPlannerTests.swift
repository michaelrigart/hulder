import Foundation
import Testing
@testable import HulderCore

struct OrderPlannerTests {
    func k(_ raw: String) -> ItemKey { ItemKey(raw: raw) }
    func ks(_ raws: [String]) -> [ItemKey] { raws.map(k) }

    /// One app per key in `sections` (bundle ID `com.example.<key>`), plus a macOS-managed item
    /// per key in `managed`. Keys in `order` that appear in neither are unknown.
    func context(
        order: [String],
        sections: [String: Section],
        managed: Set<String> = ["clock"],
        pinned: Set<String> = ["clock"],
        divider: String? = "D"
    ) -> OrderContext {
        var layout = Layout()
        var items: [MenuBarItem] = []
        let now = Date(timeIntervalSince1970: 0)
        for key in order {
            if managed.contains(key) {
                items.append(MenuBarItem(
                    key: k(key), owner: .unresolved(processName: key), isManagedByMacOS: true))
            } else if let section = sections[key] {
                let app = AppID("com.example.\(key)")
                _ = layout.recordSighting(app, name: key, at: now)
                layout.assign(app, to: section)
                items.append(MenuBarItem(key: k(key), owner: .app(app, name: key)))
            }
        }
        return OrderContext(
            order: BarOrder(keys: ks(order), pinned: Set(pinned.map(k))),
            divider: divider.map(k),
            items: items,
            layout: layout)
    }

    let fixtureSections: [String: Section] = [
        "ah1": .alwaysHidden, "h1": .hidden, "h2": .hidden, "v1": .visible, "v2": .visible,
    ]

    func fixture(divider: String? = "D") -> OrderContext {
        context(
            order: ["ah1", "h1", "h2", "D", "v1", "v2", "clock"],
            sections: fixtureSections,
            divider: divider)
    }

    @Test func toHiddenPlacesLeftOfDivider() {
        let change = OrderPlanner.placeAtDivider(ks(["v2"]), section: .hidden, in: fixture())
        #expect(change == OrderChange(
            target: ks(["ah1", "h1", "h2", "v2", "D", "v1", "clock"]), moved: ks(["v2"])))
    }

    @Test func toVisiblePlacesRightOfDivider() {
        let change = OrderPlanner.placeAtDivider(ks(["h1"]), section: .visible, in: fixture())
        #expect(change?.target == ks(["ah1", "h2", "D", "h1", "v1", "v2", "clock"]))
    }

    @Test func toAlwaysHiddenPlacesAtItsBoundary() {
        let change = OrderPlanner.placeAtDivider(ks(["v1"]), section: .alwaysHidden, in: fixture())
        #expect(change?.target == ks(["ah1", "v1", "h1", "h2", "D", "v2", "clock"]))
    }

    @Test func appItemsKeepRelativeOrder() {
        let ctx = context(
            order: ["h1", "x1", "D", "x2", "v1", "clock"],
            sections: ["h1": .hidden, "x1": .visible, "x2": .visible, "v1": .visible])
        let change = OrderPlanner.placeAtDivider(ks(["x2", "x1"]), section: .visible, in: ctx)
        #expect(change?.target == ks(["h1", "D", "x1", "x2", "v1", "clock"]))
        #expect(change?.moved == ks(["x1", "x2"]))
    }

    @Test func dropBeforeAnchor() {
        let change = OrderPlanner.drop(ks(["v2"]), section: .visible, before: k("v1"), in: fixture())
        #expect(change?.target == ks(["ah1", "h1", "h2", "D", "v2", "v1", "clock"]))
    }

    @Test func dropWithoutAnchorGoesToTheEndOfTheSectionsRow() {
        let ctx = fixture()
        #expect(OrderPlanner.drop(ks(["v1"]), section: .hidden, before: nil, in: ctx)?.target
            == ks(["ah1", "h1", "h2", "v1", "D", "v2", "clock"]))
        #expect(OrderPlanner.drop(ks(["h2"]), section: .alwaysHidden, before: nil, in: ctx)?.target
            == ks(["ah1", "h2", "h1", "D", "v1", "v2", "clock"]))
        #expect(OrderPlanner.drop(ks(["h1"]), section: .visible, before: nil, in: ctx)?.target
            == ks(["ah1", "h2", "D", "v1", "v2", "h1", "clock"]))
    }

    @Test func dropNeverLandsRightOfAPinnedKey() {
        let change = OrderPlanner.drop(ks(["h1"]), section: .visible, before: k("clock"), in: fixture())
        #expect(change?.target == ks(["ah1", "h2", "D", "v1", "v2", "h1", "clock"]))
        let pastIt = context(
            order: ["D", "v1", "clock", "wifi"],
            sections: ["v1": .visible],
            managed: ["clock", "wifi"])
        #expect(OrderPlanner.drop(ks(["v1"]), section: .visible, before: k("wifi"), in: pastIt) == nil)
    }

    @Test func firstSightingFromLeftEdge() {
        let ctx = context(
            order: ["n1", "ah1", "h1", "D", "v1", "clock"],
            sections: ["n1": .visible, "ah1": .alwaysHidden, "h1": .hidden, "v1": .visible])
        let change = OrderPlanner.placeAtDivider(ks(["n1"]), section: .visible, in: ctx)
        #expect(change?.target == ks(["ah1", "h1", "D", "n1", "v1", "clock"]))
    }

    @Test func tidyMovesOnlyMisplaced() {
        let ctx = context(
            order: ["v9", "ah1", "h1", "D", "v1", "h9", "clock"],
            sections: ["v9": .visible, "ah1": .alwaysHidden, "h1": .hidden, "v1": .visible, "h9": .hidden])
        #expect(OrderPlanner.misplaced(in: ctx) == ks(["v9", "h9"]))
        let change = OrderPlanner.tidy(in: ctx)
        #expect(change == OrderChange(
            target: ks(["ah1", "h1", "h9", "D", "v9", "v1", "clock"]), moved: ks(["h9", "v9"])))
    }

    @Test func tidyOfSomeKeysLeavesOtherMisplacedItemsAlone() {
        // v0 and h0 are misplaced too, but only the named keys are looked at.
        let ctx = context(
            order: ["v0", "D", "h0", "v1", "h1"],
            sections: ["v0": .visible, "h0": .hidden, "v1": .visible, "h1": .hidden])

        let change = OrderPlanner.tidy(in: ctx, only: [k("h1"), k("v1")])

        #expect(change == OrderChange(target: ks(["v0", "h1", "D", "h0", "v1"]), moved: ks(["h1"])))
    }

    @Test func tidyOfSomeKeysThatAreInPlaceIsNil() {
        let ctx = context(order: ["v0", "D", "h0", "v1"], sections: ["v0": .visible, "h0": .hidden, "v1": .visible])

        #expect(OrderPlanner.tidy(in: ctx, only: [k("v1")]) == nil)
    }

    @Test func tidyKeepsAlwaysHiddenLeftOfHidden() {
        let ctx = context(
            order: ["D", "h9", "a9", "v1", "clock"],
            sections: ["h9": .hidden, "a9": .alwaysHidden, "v1": .visible])
        #expect(OrderPlanner.tidy(in: ctx)?.target == ks(["a9", "h9", "D", "v1", "clock"]))
    }

    @Test func tidyOfATidyBarIsNil() {
        #expect(OrderPlanner.tidy(in: fixture()) == nil)
        #expect(OrderPlanner.misplaced(in: fixture()).isEmpty)
    }

    @Test func pinnedNeverMoves() {
        #expect(OrderPlanner.placeAtDivider(ks(["clock"]), section: .hidden, in: fixture()) == nil)
    }

    @Test func macOSItemsAreNeverMisplaced() {
        let ctx = context(
            order: ["wifi", "D", "v1", "clock"],
            sections: ["v1": .visible],
            managed: ["wifi", "clock"])
        #expect(OrderPlanner.misplaced(in: ctx).isEmpty)
        #expect(OrderPlanner.tidy(in: ctx) == nil)
    }

    @Test func macOSItemsCannotBeMovedExplicitly() {
        let ctx = context(
            order: ["D", "v1", "wifi", "clock"],
            sections: ["v1": .visible],
            managed: ["wifi", "clock"])
        #expect(OrderPlanner.drop(ks(["wifi"]), section: .visible, before: k("v1"), in: ctx) == nil)
        #expect(OrderPlanner.placeAtDivider(ks(["wifi"]), section: .hidden, in: ctx) == nil)
    }

    @Test func unresolvedOwnersCannotBeMovedExplicitly() {
        let ctx = OrderContext(
            order: BarOrder(keys: ks(["D", "v1", "u"]), pinned: []),
            divider: k("D"),
            items: [MenuBarItem(key: k("u"), owner: .unresolved(processName: "u"))],
            layout: Layout())
        #expect(OrderPlanner.placeAtDivider(ks(["u"]), section: .hidden, in: ctx) == nil)
    }

    @Test func unknownKeysAreNeverMovedOrMisplaced() {
        let ctx = context(
            order: ["ghost", "D", "v1", "ghost2", "clock"],
            sections: ["v1": .visible])
        #expect(OrderPlanner.misplaced(in: ctx).isEmpty)
        #expect(OrderPlanner.placeAtDivider(ks(["ghost"]), section: .visible, in: ctx) == nil)
    }

    @Test func noDividerPlansNothing() {
        let ctx = fixture(divider: nil)
        #expect(OrderPlanner.placeAtDivider(ks(["v2"]), section: .hidden, in: ctx) == nil)
        #expect(OrderPlanner.drop(ks(["v2"]), section: .visible, before: k("v1"), in: ctx) == nil)
        #expect(OrderPlanner.misplaced(in: ctx).isEmpty)
        #expect(OrderPlanner.tidy(in: ctx) == nil)
    }

    @Test func dividerMissingFromTheOrderPlansNothing() {
        let ctx = context(order: ["v1", "clock"], sections: ["v1": .visible], divider: "D")
        #expect(OrderPlanner.placeAtDivider(ks(["v1"]), section: .hidden, in: ctx) == nil)
        #expect(OrderPlanner.tidy(in: ctx) == nil)
    }

    @Test func alreadyInPlaceIsNil() {
        #expect(OrderPlanner.placeAtDivider(ks(["h2"]), section: .hidden, in: fixture()) == nil)
    }

    @Test func sectionOfIsNilForMacOSUnresolvedAndUnknown() {
        let ctx = context(order: ["clock", "D", "v1", "ghost"], sections: ["v1": .hidden])
        #expect(ctx.section(of: k("clock")) == nil)
        #expect(ctx.section(of: k("ghost")) == nil)
        #expect(ctx.section(of: k("v1")) == .hidden)
        let unresolved = OrderContext(
            order: BarOrder(keys: ks(["u", "D"]), pinned: []),
            divider: k("D"),
            items: [MenuBarItem(key: k("u"), owner: .unresolved(processName: "u"))],
            layout: Layout())
        #expect(unresolved.section(of: k("u")) == nil)
    }

    // MARK: - Apple's items

    let wifi = SystemItemID(moduleName: "WiFi")
    let systemUIServer = AppID("com.apple.systemuiserver")

    /// Wi-Fi, Siri and Focus left of the divider, with the default section Hidden, the unknown app u left of the
    /// divider and the Visible app v1 right of it.
    func appleContext(_ layout: Layout = Layout()) -> OrderContext {
        var layout = layout
        layout.defaultSection = .hidden
        _ = layout.recordSighting(AppID("com.example.v1"), name: "v1", at: Date(timeIntervalSince1970: 0))
        layout.assign(AppID("com.example.v1"), to: .visible)
        let agent = ItemOwner.app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent")
        return OrderContext(
            order: BarOrder(keys: ks(["wifi", "siri", "focus", "u", "D", "v1"]), pinned: []),
            divider: k("D"),
            items: [
                MenuBarItem(key: k("wifi"), owner: agent, isManagedByMacOS: true, systemItem: wifi),
                MenuBarItem(key: k("siri"), owner: .app(systemUIServer, name: "SystemUIServer")),
                MenuBarItem(key: k("focus"), owner: agent, isManagedByMacOS: true),
                MenuBarItem(key: k("v1"), owner: .app(AppID("com.example.v1"), name: "v1")),
                MenuBarItem(key: k("u"), owner: .app(AppID("com.example.u"), name: "u")),
            ],
            layout: layout)
    }

    @Test func anUnassignedAppleItemHasNoSectionAndAppsKeepTheirs() {
        let ctx = appleContext()

        #expect(ctx.section(of: k("wifi")) == nil)
        #expect(ctx.section(of: k("siri")) == nil)
        #expect(ctx.section(of: k("focus")) == nil)
        #expect(ctx.section(of: k("v1")) == .visible)
        #expect(ctx.section(of: k("u")) == .hidden)
    }

    @Test func anAssignedAppleItemHasItsSection() {
        var layout = Layout()
        layout.assign(wifi, to: .alwaysHidden)
        _ = layout.recordSighting(systemUIServer, name: "SystemUIServer", at: Date(timeIntervalSince1970: 0))
        layout.assign(systemUIServer, to: .visible)
        let ctx = appleContext(layout)

        #expect(ctx.section(of: k("wifi")) == .alwaysHidden)
        #expect(ctx.section(of: k("siri")) == .visible)
        #expect(ctx.section(of: k("v1")) == .visible)
    }

    @Test func anUnassignedAppleItemLeftOfTheDividerIsNotMisplacedUntilAssignedVisible() {
        #expect(OrderPlanner.misplaced(in: appleContext()).isEmpty)
        #expect(OrderPlanner.tidy(in: appleContext()) == nil)

        var layout = Layout()
        layout.assign(wifi, to: .visible)
        #expect(OrderPlanner.misplaced(in: appleContext(layout)) == [k("wifi")])
    }
}
