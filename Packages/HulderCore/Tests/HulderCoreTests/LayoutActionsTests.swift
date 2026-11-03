import Foundation
import Testing
@testable import HulderCore

@MainActor
struct LayoutActionsTests {
    private let noIcon = "Hulder's icon isn't on the menu bar."
    private let unsavedIcon = "macOS hasn't saved where Hulder's icon is yet. ⌘-drag it once, then try again."
    private let noReordering = "Reordering needs access to the menu bar order file."
    private let ownApp = AppID("com.michaelrigart.hulder")

    private func k(_ raw: String) -> ItemKey { ItemKey(raw: raw) }
    private func ks(_ raws: String...) -> [ItemKey] { raws.map(k) }
    private func app(_ id: String) -> AppID { AppID("com.example.\(id)") }

    @MainActor
    private final class Harness {
        let directory: URL
        let state: StateModel
        let menuBar: MenuBarModel
        let orderStore: FakeOrderStore
        let clock = ManualClock()
        let controller: OrderController
        let actions: LayoutActions

        /// `order` lists item keys; each key `x` belongs to app `com.example.x` unless `owners` says
        /// otherwise, or is the item `items` gives for it. Every app in `sections` is recorded and assigned. "D" is
        /// Hulder's own icon.
        init(
            order: [String],
            sections: [String: Section],
            owners: [String: String] = [:],
            items: [String: MenuBarItem] = [:],
            pinned: Set<String> = [],
            drawn: [String]? = nil,
            uncertain: Set<String> = [],
            script: FakeOrderStore.Script = .init(),
            withController: Bool = true,
            withDivider: Bool = true
        ) {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            state = StateModel(store: StateStore(fileURL: directory.appendingPathComponent("state.json")))
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            for (id, section) in sections {
                state.recordSightings([(AppID("com.example.\(id)"), id.uppercased())], at: t)
                state.assign(AppID("com.example.\(id)"), to: section)
            }
            menuBar = MenuBarModel()
            menuBar.inventory = InventorySnapshot(
                items: order.map { key in
                    if let item = items[key] {
                        var item = item
                        item.orderKeyIsCertain = !uncertain.contains(key)
                        return item
                    }
                    if key == "D" {
                        return MenuBarItem(
                            key: ItemKey(raw: key), owner: .app(AppID("com.michaelrigart.hulder"), name: "Hulder"))
                    }
                    let id = owners[key] ?? key
                    return MenuBarItem(
                        key: ItemKey(raw: key), owner: .app(AppID("com.example.\(id)"), name: id.uppercased()),
                        orderKeyIsCertain: !uncertain.contains(key))
                },
                stale: [])
            let bar = BarOrder(keys: order.map { ItemKey(raw: $0) }, pinned: Set(pinned.map { ItemKey(raw: $0) }))
            menuBar.order = bar
            menuBar.divider = withDivider ? ItemKey(raw: "D") : nil
            orderStore = FakeOrderStore(
                order: bar, drawn: Set((drawn ?? order).map { ItemKey(raw: $0) }), script: script)
            controller = OrderController(store: orderStore, clock: clock)
            actions = LayoutActions(state: state, menuBar: menuBar, order: withController ? controller : nil)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        var layout: Layout { state.state.layout }

        func writes() async -> [OrderChange] {
            await orderStore.log.compactMap {
                if case .write(let change) = $0 { change } else { nil }
            }
        }

        /// The planner's answer for the current state.
        func context() -> OrderContext {
            OrderContext(
                order: menuBar.order ?? BarOrder(keys: [], pinned: []),
                divider: menuBar.divider, items: menuBar.inventory.items, layout: layout)
        }
    }

    private let standard = ["h1", "h2", "D", "v1", "v2"]
    private let standardSections: [String: Section] = ["h1": .hidden, "h2": .hidden, "v1": .visible, "v2": .visible]

    @Test func moveToHiddenAssignsAndPlacesAtDivider() async throws {
        let h = Harness(order: standard, sections: standardSections)

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .done)

        #expect(h.layout.section(of: app("v1")) == .hidden)
        let expected = try #require(OrderPlanner.placeAtDivider(ks("v1"), section: .hidden, in: h.context()))
        #expect(expected.target == ks("h1", "h2", "v1", "D", "v2"))
        #expect(await h.writes() == [expected])
    }

    @Test func moveWithoutReorderingStillAssigns() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .done)

        #expect(h.layout.section(of: app("v1")) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func moveToTheSameSectionWithoutReorderingIsUnchanged() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.move(.app(app("v1")), to: .visible) == .unchanged)
    }

    @Test func dropWithinSectionWithoutReorderingIsUnavailable() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.drop(k("h2"), to: .hidden, before: k("h1")) == .unavailable(noReordering))
        #expect(h.layout.section(of: app("h2")) == .hidden)
    }

    @Test func dropToAnotherSectionWithoutReorderingStillAssigns() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.drop(k("v1"), to: .hidden, before: k("h1")) == .done)
        #expect(h.layout.section(of: app("v1")) == .hidden)
    }

    @Test func noDividerMakesReorderingUnavailable() async {
        let h = Harness(order: standard, sections: standardSections, withDivider: false)

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .unavailable(noIcon))

        #expect(h.layout.section(of: app("v1")) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func aDividerThatIsNotInTheOrderAsksForACommandDrag() async {
        // The icon is drawn, but macOS has no entry for it yet, so nothing can be placed against it.
        let h = Harness(order: ["h1", "v1", "v2"], sections: ["h1": .hidden, "v1": .visible, "v2": .visible])
        #expect(h.menuBar.divider == k("D"))

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .unavailable(unsavedIcon))
        #expect(await h.actions.drop(k("v2"), to: .visible, before: k("v1")) == .unavailable(unsavedIcon))
        #expect(await h.actions.tidy() == .unavailable(unsavedIcon))
        await h.actions.recordSightings(sightings("v1"), orderEntriesAvailable: true, at: Self.date)

        #expect(await h.orderStore.log.isEmpty)
        #expect(h.menuBar.failures.isEmpty)
    }

    @Test func noDividerAtAllKeepsTheIconIsNotOnTheBarText() async {
        let h = Harness(order: standard, sections: standardSections, withDivider: false)

        #expect(await h.actions.drop(k("v2"), to: .visible, before: k("v1")) == .unavailable(noIcon))
        #expect(await h.actions.tidy() == .unavailable(noIcon))
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func noDividerMakesADropWithinASectionUnavailable() async {
        let h = Harness(order: standard, sections: standardSections, withDivider: false)

        #expect(await h.actions.drop(k("h2"), to: .hidden, before: k("h1")) == .unavailable(noIcon))
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func nativeReorderOnlyUpdatesTheModel() async {
        let h = Harness(order: standard, sections: standardSections)
        #expect(h.menuBar.misplaced(layout: h.layout).isEmpty)
        let before = h.layout

        // A native Command-drag moves h1 to the right of the divider.
        h.menuBar.order = BarOrder(keys: ks("h2", "D", "h1", "v1", "v2"), pinned: [])

        #expect(h.layout == before)
        #expect(h.menuBar.misplaced(layout: h.layout) == [k("h1")])
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func moveOfAnAppThatWasNeverRecordedChangesItsSection() async throws {
        let h = Harness(order: ["D", "x1"], sections: [:], owners: ["x1": "x"], withController: false)
        #expect(h.layout.apps[app("x")] == nil)

        #expect(await h.actions.move(.app(app("x")), to: .alwaysHidden) == .done)

        #expect(h.layout.section(of: app("x")) == .alwaysHidden)
        #expect(h.layout.apps[app("x")]?.name == "X")
    }

    @Test func dropOfAnItemOfAnAppThatWasNeverRecordedChangesItsSection() async {
        let h = Harness(order: ["D", "x1"], sections: [:], owners: ["x1": "x"], withController: false)

        #expect(await h.actions.drop(k("x1"), to: .hidden, before: nil) == .done)

        #expect(h.layout.section(of: app("x")) == .hidden)
    }

    @Test func hulderItselfCannotBeMovedOrDropped() async {
        let h = Harness(order: standard, sections: standardSections)

        #expect(await h.actions.move(.app(ownApp), to: .hidden) == .unchanged)
        #expect(await h.actions.drop(k("D"), to: .hidden, before: k("h1")) == .unchanged)

        #expect(h.layout.apps[ownApp] == nil)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func dropWithAVanishedAnchorFallsBackToTheEndOfTheRow() async throws {
        let h = Harness(order: standard, sections: standardSections)
        #expect(OrderPlanner.drop(ks("v1"), section: .hidden, before: k("gone"), in: h.context()) == nil)

        #expect(await h.actions.drop(k("v1"), to: .hidden, before: k("gone")) == .done)

        let writes = await h.writes()
        #expect(writes.map(\.target) == [ks("h1", "h2", "v1", "D", "v2")])
    }

    @Test func dropWithinAVisibleSectionUsesTheAnchor() async {
        let h = Harness(order: standard, sections: standardSections)

        #expect(await h.actions.drop(k("v2"), to: .visible, before: k("v1")) == .done)

        #expect(await h.writes().map(\.target) == [ks("h1", "h2", "D", "v2", "v1")])
    }

    @Test func dropToAnotherSectionPutsTheDroppedItemAtTheDropPointAndTheRestAtTheDivider() async {
        let h = Harness(
            order: ["h1", "h2", "D", "a1", "v1", "a2"],
            sections: ["h1": .hidden, "h2": .hidden, "v1": .visible, "a": .visible],
            owners: ["a1": "a", "a2": "a"])

        #expect(await h.actions.drop(k("a1"), to: .hidden, before: k("h1")) == .done)

        #expect(h.layout.section(of: app("a")) == .hidden)
        let writes = await h.writes()
        #expect(writes.map(\.target) == [ks("a1", "h1", "h2", "a2", "D", "v1")])
        #expect(writes.first?.moved == ks("a1", "a2"))
    }

    @Test func hiddenReorderReportsSaved() async {
        let h = Harness(
            order: standard, sections: standardSections,
            drawn: ["D", "v1", "v2"])

        #expect(await h.actions.drop(k("h2"), to: .hidden, before: k("h1")) == .saved)

        #expect(h.menuBar.failures.isEmpty)
        #expect(await h.writes().map(\.target) == [ks("h2", "h1", "D", "v1", "v2")])
    }

    @Test func aMoveToTheSectionAnItemIsAlreadyInIsUnchanged() async {
        let h = Harness(order: standard, sections: standardSections)

        #expect(await h.actions.move(.app(app("v1")), to: .visible) == .unchanged)
        #expect(await h.writes().isEmpty)
    }

    @Test func aSectionChangeWhoseOrderIsAlreadyRightIsDone() async {
        // h2 is recorded as Visible but already sits left of the divider, where Hidden items go.
        let h = Harness(order: standard, sections: ["h1": .hidden, "h2": .visible, "v1": .visible, "v2": .visible])

        #expect(await h.actions.move(.app(app("h2")), to: .hidden) == .done)

        #expect(h.layout.section(of: app("h2")) == .hidden)
        #expect(await h.writes().isEmpty)
    }

    @Test func unconfirmedOrderRecordsAFailure() async throws {
        let h = Harness(order: standard, sections: standardSections, script: .init(writeEffect: .silent))
        let move = Task { await h.actions.move(.app(app("v1")), to: .hidden) }
        try #require(await waitUntil { h.clock.sleepsRequested == 4 && h.clock.sleeperCount == 1 })

        await h.clock.advance(by: .seconds(3))

        #expect(await move.value == .failed(.orderUnconfirmed))
        #expect(h.menuBar.lastFailure == .orderUnconfirmed)
    }

    @Test func anOrderThatKeepsChangingRecordsAGaveUpFailure() async {
        let h = Harness(order: standard, sections: standardSections, script: .init(staleWrites: 2))

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .failed(.orderGaveUp))
        #expect(h.menuBar.lastFailure == .orderGaveUp)
    }

    @Test func aWriteErrorRecordsAWriteFailure() async {
        let h = Harness(order: standard, sections: standardSections, script: .init(writeError: .io))

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .failed(.orderWriteFailed))
        #expect(h.menuBar.lastFailure == .orderWriteFailed)
    }

    @Test func anUnavailableOrderStoreIsPassedOnWithoutAFailure() async {
        let h = Harness(order: standard, sections: standardSections, script: .init(readError: .noAccess))

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .unavailable("No access to the order file"))
        #expect(h.menuBar.failures.isEmpty)
        #expect(h.layout.section(of: app("v1")) == .hidden)
    }

    @Test func tidyMovesMisplacedItemsToTheirSide() async {
        // v1 is Visible but sits left of the divider.
        let h = Harness(order: ["v1", "D"], sections: ["v1": .visible])
        #expect(h.menuBar.misplaced(layout: h.layout) == [k("v1")])

        #expect(await h.actions.tidy() == .done)

        #expect(await h.writes().map(\.target) == [ks("D", "v1")])
    }

    @Test func tidyWithNothingMisplacedIsUnchanged() async {
        let h = Harness(order: standard, sections: standardSections)

        #expect(await h.actions.tidy() == .unchanged)
    }

    @Test func tidyNeedsTheOrderControllerAndTheDivider() async {
        let noController = Harness(order: standard, sections: standardSections, withController: false)
        let noDivider = Harness(order: standard, sections: standardSections, withDivider: false)

        #expect(await noController.actions.tidy() == .unavailable(noReordering))
        #expect(await noDivider.actions.tidy() == .unavailable(noIcon))
    }

    @Test func restoreOrderRestoresTheLatestBackup() async {
        let backup = BarOrder(keys: ks("h2", "h1", "D", "v1", "v2"), pinned: [])
        let h = Harness(order: standard, sections: standardSections, script: .init(backupOrder: backup))

        #expect(await h.actions.restoreOrder() == .done)

        #expect(await h.orderStore.order == backup)
    }

    @Test func restoreOrderNeedsTheOrderController() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.restoreOrder() == .unavailable(noReordering))
    }

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func sightings(_ ids: String...) -> [(AppID, String)] {
        ids.map { (app($0), $0.uppercased()) }
    }

    @Test func firstSightingsAlreadyOnTheirSideOfTheDividerWriteNothing() async {
        // A launch with an empty layout over a bar the user arranged: the default is Visible, and every
        // app is already right of the divider.
        let h = Harness(order: ["x", "D", "a", "b", "c"], sections: [:])

        await h.actions.recordSightings(sightings("a", "b", "c"), orderEntriesAvailable: true, at: Self.date)

        #expect(Set(h.layout.apps.keys) == [app("a"), app("b"), app("c")])
        #expect(await h.orderStore.log == [.read])
        #expect(await h.orderStore.order.keys == ks("x", "D", "a", "b", "c"))
        #expect(h.menuBar.failures.isEmpty)
    }

    @Test func newHiddenAppsMoveTogetherInOrderInOneWrite() async {
        let h = Harness(
            order: ["h1", "D", "v1", "n1", "n2"], sections: ["h1": .hidden, "v1": .visible],
            owners: ["n1": "n", "n2": "m"])
        h.state.setDefaultSection(.hidden)

        await h.actions.recordSightings(sightings("n", "m"), orderEntriesAvailable: true, at: Self.date)

        let writes = await h.writes()
        #expect(writes.map(\.target) == [ks("h1", "n1", "n2", "D", "v1")])
        #expect(writes.first?.moved == ks("n1", "n2"))
        #expect(await h.orderStore.log.filter { $0 == .backup }.count == 1)
    }

    // New apps all take the default section, so the mix is of positions: n is in place, m is not, and v0 is
    // misplaced but not new.
    @Test func aMixOfNewAppsMovesOnlyTheMisplacedOnes() async {
        let h = Harness(
            order: ["v0", "n1", "h1", "D", "v1", "m1"],
            sections: ["v0": .visible, "h1": .hidden, "v1": .visible],
            owners: ["n1": "n", "m1": "m"])
        h.state.setDefaultSection(.hidden)

        await h.actions.recordSightings(sightings("n", "m"), orderEntriesAvailable: true, at: Self.date)

        let writes = await h.writes()
        #expect(writes.map(\.target) == [ks("v0", "n1", "h1", "m1", "D", "v1")])
        #expect(writes.first?.moved == ks("m1"))
        #expect(await h.orderStore.log.filter { $0 == .backup }.count == 1)
    }

    @Test func firstSightingsWithoutADividerRecordTheAppAndWriteNothing() async {
        let h = Harness(
            order: ["h1", "D", "v1", "n1"], sections: ["h1": .hidden, "v1": .visible], owners: ["n1": "n"],
            withDivider: false)

        await h.actions.recordSightings(sightings("n"), orderEntriesAvailable: true, at: Self.date)

        #expect(h.layout.apps[app("n")] != nil)
        #expect(await h.orderStore.log.isEmpty)
        #expect(h.menuBar.failures.isEmpty)
    }

    @Test func hulderItselfIsNeverPlacedAsAFirstSighting() async {
        let h = Harness(order: ["v1", "D"], sections: ["v1": .visible])

        await h.actions.recordSightings([(ownApp, "Hulder")], orderEntriesAvailable: true, at: Self.date)

        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func theOrderControllerCanBeSetLater() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)
        let controller = h.controller

        h.actions.setOrderController(controller)

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .done)
        #expect(await h.writes().count == 1)
    }

    // MARK: - Start-up sightings

    private let refused = "Order file access isn't granted."

    /// A bar the user arranged, with Hidden as the default section: n1 and n2 are new and sit right of the divider.
    private func startUp() -> Harness {
        let h = Harness(
            order: ["h1", "D", "v1", "n1", "n2"], sections: ["h1": .hidden, "v1": .visible],
            owners: ["n1": "n", "n2": "m"], withController: false)
        h.state.setDefaultSection(.hidden)
        return h
    }

    private func isRecorded(_ h: Harness, _ ids: String...) -> Bool {
        ids.allSatisfy { h.layout.apps[app($0)] != nil }
    }

    private func isUnrecorded(_ h: Harness, _ ids: String...) -> Bool {
        ids.allSatisfy { h.layout.apps[app($0)] == nil }
    }

    // Round 1: catches sightings consumed before the controller is there.
    @Test func anAppSeenBeforeTheControllerIsReadyStaysNewUntilAPassCanPlaceIt() async {
        let h = startUp()
        let apps = sightings("n", "m")

        h.actions.reorderingChanged(.notChecked)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)
        #expect(isUnrecorded(h, "n", "m"))
        #expect(await h.orderStore.log.isEmpty)

        h.actions.reorderingChanged(.available)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)
        #expect(isUnrecorded(h, "n", "m"))
        #expect(await h.orderStore.log.isEmpty)

        h.actions.setOrderController(h.controller)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)

        #expect(isRecorded(h, "n", "m"))
        #expect(await h.writes().map(\.target) == [ks("h1", "n1", "n2", "D", "v1")])
        #expect(await h.orderStore.log.filter { $0 == .backup }.count == 1)
    }

    // Round 3: catches the start-up queue cleared by `stopOrder()` on a `.notChecked` update.
    @Test func capabilityUpdatesBeforeTheFirstAnswerLoseNothing() async {
        let h = startUp()
        let apps = sightings("n", "m")
        await h.actions.recordSightings(apps, orderEntriesAvailable: false, at: Self.date)

        for _ in 0..<3 {
            h.actions.reorderingChanged(.notChecked)
            h.actions.removeOrderController()
        }
        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)

        #expect(isRecorded(h, "n", "m"))
        #expect(await h.writes().map(\.target) == [ks("h1", "n1", "n2", "D", "v1")])
    }

    // Round 2 (1), R61(1): catches a sighting used up by an inventory keyed without the order file.
    @Test func aPassWithoutOrderEntriesRecordsNoNewAppEvenWithAController() async {
        let h = startUp()
        let apps = sightings("n", "m")
        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)

        await h.actions.recordSightings(apps, orderEntriesAvailable: false, at: Self.date)
        #expect(isUnrecorded(h, "n", "m"))
        #expect(await h.orderStore.log.isEmpty)

        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)
        #expect(isRecorded(h, "n", "m"))
        #expect(await h.writes().map(\.target) == [ks("h1", "n1", "n2", "D", "v1")])
    }

    // R62: catches the pass in flight at the controller's install placing made-up keys. Before the order file was
    // readable the scan named the items `Item-0`; afterwards, `Alpha`. Only the second key is in the order file.
    @Test func theAppsArePlacedWithTheKeysOfThePassThatReadTheOrderFile() async {
        let h = Harness(
            order: ["h1", "D", "v1", "n::Alpha", "m::Alpha"], sections: ["h1": .hidden, "v1": .visible],
            owners: ["n::Alpha": "n", "m::Alpha": "m"], withController: false)
        h.state.setDefaultSection(.hidden)
        let keyedAfter = h.menuBar.inventory
        h.menuBar.inventory = InventorySnapshot(
            items: keyedAfter.items.map { item in
                guard item.owner.appID != nil, item.key.raw.hasSuffix("::Alpha") else { return item }
                return MenuBarItem(key: k(item.key.raw.replacingOccurrences(of: "::Alpha", with: "::Item-0")), owner: item.owner)
            },
            stale: [])
        let apps = sightings("n", "m")
        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)

        await h.actions.recordSightings(apps, orderEntriesAvailable: false, at: Self.date)
        #expect(await h.orderStore.log.isEmpty)

        h.menuBar.inventory = keyedAfter
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)

        #expect(await h.writes().map(\.target) == [ks("h1", "n::Alpha", "m::Alpha", "D", "v1")])
    }

    // R56: catches a later grant moving icons the user arranged since.
    @Test func anAppSeenWhileReorderingIsRefusedIsRecordedAndNeverPlacedByALaterGrant() async {
        let h = startUp()
        let apps = sightings("n", "m")
        h.actions.reorderingChanged(.unavailable(refused))

        await h.actions.recordSightings(apps, orderEntriesAvailable: false, at: Self.date)
        #expect(isRecorded(h, "n", "m"))

        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)

        #expect(await h.orderStore.log.isEmpty)
    }

    // R56.
    @Test func anAppSeenWhileTheStoreCannotBeOpenedIsRecordedAndNotPlaced() async {
        let h = startUp()
        let apps = sightings("n", "m")
        h.actions.reorderingChanged(.available)
        h.actions.orderControllerUnobtainable()

        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)
        #expect(isRecorded(h, "n", "m"))

        h.actions.setOrderController(h.controller)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)

        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func anAppSeenAfterReorderingWasLostIsRecordedAndNotPlacedByTheNextController() async {
        let h = startUp()
        let apps = sightings("n", "m")
        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        h.actions.reorderingChanged(.unavailable(refused))
        h.actions.removeOrderController()

        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)
        #expect(isRecorded(h, "n", "m"))

        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        await h.actions.recordSightings(apps, orderEntriesAvailable: true, at: Self.date)

        #expect(await h.orderStore.log.isEmpty)
    }

    // Catches `.wait` freezing the names and days of known apps.
    @Test func aPassThatCannotPlaceKeepsKnownAppsCurrent() async {
        let h = startUp()

        await h.actions.recordSightings(
            [(app("v1"), "Renamed"), (app("n"), "N")], orderEntriesAvailable: true, at: Self.date)

        #expect(h.layout.apps[app("v1")]?.name == "Renamed")
        #expect(isUnrecorded(h, "n"))
    }

    // Review of this task, round 2: catches an app left new by a waiting pass staying unrecorded on an idle bar, then
    // being placed by a later grant.
    @Test func leavingWaitAsksForAScan() {
        let refusedNow = startUp().actions
        #expect(refusedNow.reorderingChanged(.notChecked) == false)
        #expect(refusedNow.reorderingChanged(.unavailable(refused)) == true)

        let unobtainable = startUp().actions
        #expect(unobtainable.reorderingChanged(.available) == false)
        #expect(unobtainable.orderControllerUnobtainable() == true)

        let h = startUp()
        #expect(h.actions.reorderingChanged(.available) == false)
        #expect(h.actions.setOrderController(h.controller) == true)
        #expect(h.actions.setOrderController(h.controller) == false)
        #expect(h.actions.removeOrderController() == false)
    }

    // Catches an initial availability other than `.notChecked`, which is round 1's bug.
    @Test func aPassBeforeAnyCapabilityAnswerRecordsNothingNew() async {
        let h = startUp()

        await h.actions.recordSightings(sightings("n"), orderEntriesAvailable: true, at: Self.date)

        #expect(isUnrecorded(h, "n"))
        #expect(await h.orderStore.log.isEmpty)
    }

    // MARK: - A hidden new app, through the real chain

    private let hulder = ItemOwner.app(AppID("com.michaelrigart.hulder"), name: "Hulder")

    /// One pass of the chain `AppComposition.scanned` runs: the memory, the inventory, the sightings, the recording.
    private func scan(_ pass: ScanPass, _ memory: inout InventoryMemory, _ h: Harness) async {
        let snapshot = memory.apply(pass)
        h.menuBar.inventory = snapshot
        let found = SightingRecorder.sightings(in: snapshot, own: ownApp, known: Set(h.layout.apps.keys))
        await h.actions.recordSightings(found, orderEntriesAvailable: pass.orderEntriesAvailable, at: Self.date)
    }

    private func hiddenNewAppHarness(order: [String]) -> Harness {
        let h = Harness(
            order: order, sections: ["h": .hidden, "v": .visible],
            owners: ["h1": "h", "v1": "v", "x::Alpha": "x"], withController: false)
        h.state.setDefaultSection(.hidden)
        return h
    }

    private func owner(_ id: String) -> ItemOwner { .app(app(id), name: id.uppercased()) }

    private func item(_ key: String, _ owner: ItemOwner, at position: Double? = nil) -> MenuBarItem {
        MenuBarItem(key: k(key), owner: owner, barPosition: position)
    }

    /// The pass the bar gives: Hulder's icon and `v1` drawn, `h` hidden with its entry item, plus `extra`.
    private func barPass(
        drawn extra: [OwnerItems] = [], concealed more: [OwnerItems] = [], entries: Bool = true
    ) -> ScanPass {
        ScanPass(
            drawn: [
                OwnerItems(owner: hulder, items: [item("D", hulder, at: 10)]),
                OwnerItems(owner: owner("v"), items: [item("v1", owner("v"), at: 50)]),
            ] + extra,
            concealed: [OwnerItems(owner: owner("h"), items: [item("h1", owner("h"))])] + more,
            orderEntriesAvailable: entries)
    }

    // Review of this task, finding 1: catches a hidden new app never recorded.
    @Test func aNewAppHiddenAfterAWaitingPassIsPlacedOnceTheOrderCanBeWritten() async {
        let h = hiddenNewAppHarness(order: ["h1", "D", "v1", "x::Alpha"])
        let x = owner("x")
        var memory = InventoryMemory()

        await scan(barPass(drawn: [OwnerItems(owner: x, items: [item("x::Alpha", x, at: 90)])]), &memory, h)
        #expect(isUnrecorded(h, "x"))

        let hiddenPass = barPass(concealed: [OwnerItems(owner: x, items: [item("x::Alpha", x)])])
        await scan(hiddenPass, &memory, h)
        #expect(isUnrecorded(h, "x"))
        #expect(h.menuBar.inventory.stale.contains("com.example.x"))

        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        await scan(hiddenPass, &memory, h)

        #expect(h.layout.section(of: app("x")) == .hidden)
        #expect(await h.writes().map(\.target) == [ks("h1", "x::Alpha", "D", "v1")])
    }

    // The first pass drew the made-up key `Item-0`; the order file's entry for the hidden app replaces it.
    @Test func aNewAppDrawnBeforeTheOrderFileWasReadTakesTheFilesKeyWhenHidden() async {
        let h = hiddenNewAppHarness(order: ["h1", "D", "v1", "x::Alpha"])
        let x = owner("x")
        var memory = InventoryMemory()

        await scan(barPass(drawn: [OwnerItems(owner: x, items: [item("x::Item-0", x, at: 90)])], entries: false), &memory, h)
        #expect(isUnrecorded(h, "x"))

        let hiddenPass = barPass(concealed: [OwnerItems(owner: x, items: [item("x::Alpha", x)])])
        await scan(hiddenPass, &memory, h)
        #expect(isUnrecorded(h, "x"))
        #expect(h.menuBar.inventory.items.filter { $0.owner == x }.map(\.key.raw) == ["x::Alpha"])
        #expect(!h.menuBar.inventory.stale.contains("com.example.x"))

        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        await scan(hiddenPass, &memory, h)

        #expect(await h.writes().map(\.target) == [ks("h1", "x::Alpha", "D", "v1")])
    }

    // The order file has no entry for the app: it is recorded and nothing moves.
    @Test func aNewAppHiddenWithoutAnOrderEntryIsRecordedAndNothingMoves() async {
        let h = hiddenNewAppHarness(order: ["h1", "D", "v1"])
        let x = owner("x")
        var memory = InventoryMemory()

        await scan(barPass(drawn: [OwnerItems(owner: x, items: [item("x::Item-0", x, at: 90)])]), &memory, h)
        #expect(isUnrecorded(h, "x"))

        let hiddenPass = barPass(concealed: [OwnerItems(owner: x, items: [])])
        await scan(hiddenPass, &memory, h)
        #expect(isUnrecorded(h, "x"))
        #expect(h.menuBar.inventory.items.filter { $0.owner == x }.map(\.key.raw) == ["x::Item-0"])
        #expect(h.menuBar.inventory.stale.contains("com.example.x"))

        h.actions.reorderingChanged(.available)
        h.actions.setOrderController(h.controller)
        await scan(hiddenPass, &memory, h)

        #expect(h.layout.section(of: app("x")) == .hidden)
        #expect(await h.writes().isEmpty)
    }

    // MARK: - Uncertain order keys

    private let apart =
        "Hulder can't tell this item apart from the others in macOS's saved order. ⌘-drag it on the menu bar instead."

    @Test func anAppWithAnUncertainKeyMovesToItsNewSectionWithoutAnOrderWrite() async {
        let h = Harness(order: standard, sections: standardSections, uncertain: ["v1"])

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .sectionChangedInPlace(.hidden, .uncertainKey))

        #expect(h.layout.section(of: app("v1")) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func movingAnUncertainAppToItsOwnSectionIsRefusedWithoutAWrite() async {
        let h = Harness(order: standard, sections: standardSections, uncertain: ["v1"])

        #expect(await h.actions.move(.app(app("v1")), to: .visible) == .unavailable(apart))

        #expect(h.layout.section(of: app("v1")) == .visible)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func theNoticeForASectionChangeInPlaceNamesTheSectionAndTheAdvice() {
        #expect(LayoutOutcome.sectionChangedInPlace(.hidden, .uncertainKey).notice == LayoutNotice(
            text: "Moved to Hidden. Hulder can't tell this item apart from the others in macOS's saved order, "
                + "so it stays where it is. ⌘-drag it on the menu bar.",
            isProblem: false))
    }

    @Test func movingAnAppWithoutAnOrderControllerStillAssignsEvenIfAnItemIsUncertain() async {
        let h = Harness(order: standard, sections: standardSections, uncertain: ["v1"], withController: false)

        #expect(await h.actions.move(.app(app("v1")), to: .hidden) == .done)
        #expect(h.layout.section(of: app("v1")) == .hidden)
    }

    @Test func droppingAnUncertainItemWithinItsSectionIsRefusedWithoutAWrite() async {
        let h = Harness(order: standard, sections: standardSections, uncertain: ["v2"])

        #expect(await h.actions.drop(k("v2"), to: .visible, before: k("v1")) == .unavailable(apart))

        #expect(h.layout.section(of: app("v2")) == .visible)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func droppingAnUncertainItemAcrossSectionsAssignsTheSectionWithoutAnOrderWrite() async {
        let h = Harness(order: standard, sections: standardSections, uncertain: ["v2"])

        #expect(await h.actions.drop(k("v2"), to: .hidden, before: k("h1"))
            == .sectionChangedInPlace(.hidden, .uncertainKey))

        #expect(h.layout.section(of: app("v2")) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func droppingAcrossSectionsAssignsTheSectionWhenAnotherItemOfTheAppIsUncertain() async {
        let h = Harness(
            order: ["h1", "D", "v1", "x1", "x2"],
            sections: ["h1": .hidden, "v1": .visible, "x": .visible],
            owners: ["x1": "x", "x2": "x"], uncertain: ["x2"])

        #expect(await h.actions.drop(k("x1"), to: .hidden, before: k("h1"))
            == .sectionChangedInPlace(.hidden, .uncertainKey))

        #expect(h.layout.section(of: app("x")) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func droppingWithinASectionIgnoresAnotherUncertainItemOfTheApp() async {
        let h = Harness(
            order: ["h1", "D", "v1", "x1", "x2"],
            sections: ["h1": .hidden, "v1": .visible, "x": .visible],
            owners: ["x1": "x", "x2": "x"], uncertain: ["x2"])

        #expect(await h.actions.drop(k("x1"), to: .visible, before: k("v1")) == .done)
        #expect(await h.writes().map(\.target) == [ks("h1", "D", "x1", "v1", "x2")])
    }

    @Test func tidyMovesTheCertainMisplacedItemsAndLeavesTheUncertainOnes() async {
        // v1 and v2 (Visible) sit left of the divider; v1's key is uncertain.
        let h = Harness(
            order: ["h1", "v1", "v2", "D"], sections: ["v1": .visible, "v2": .visible, "h1": .hidden],
            uncertain: ["v1"])

        #expect(await h.actions.tidy() == .done)

        #expect(await h.writes().map(\.target) == [ks("h1", "v1", "D", "v2")])
    }

    @Test func tidyWithOnlyUncertainMisplacedItemsSaysWhyNothingMoved() async {
        let h = Harness(
            order: ["h1", "v1", "D"], sections: ["v1": .visible, "h1": .hidden], uncertain: ["v1"])

        #expect(await h.actions.tidy() == .unavailable(apart))
        #expect(await h.writes().isEmpty)
    }

    @Test func tidyWithNothingMisplacedIsStillUnchangedWhenAnItemIsUncertain() async {
        let h = Harness(order: standard, sections: standardSections, uncertain: ["v1"])

        #expect(await h.actions.tidy() == .unchanged)
    }

    @Test func firstSightingsSkipUncertainItemsSilently() async {
        let h = Harness(
            order: ["h1", "D", "v1", "n1", "n2"], sections: ["h1": .hidden, "v1": .visible],
            owners: ["n1": "n", "n2": "m"], uncertain: ["n1"])
        h.state.setDefaultSection(.hidden)

        await h.actions.recordSightings(sightings("n", "m"), orderEntriesAvailable: true, at: Self.date)

        #expect(await h.writes().map(\.target) == [ks("h1", "n2", "D", "v1", "n1")])
        #expect(h.menuBar.failures.isEmpty)
    }

    // MARK: - Apple's items

    private let pinnedText = "macOS keeps this item at the right end of the bar."
    private let wifi = SystemItemID(moduleName: "WiFi")
    private let clock = SystemItemID(moduleName: "Clock")
    private let systemUIServer = AppID("com.apple.systemuiserver")

    private func module(_ name: String, at position: Double? = 1) -> MenuBarItem {
        MenuBarItem(
            key: k(name == "BentoBox" ? "module:BentoBox-0" : "module:\(name)"),
            owner: .app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent"), isManagedByMacOS: true,
            barPosition: position, systemItem: SystemItemID(moduleName: name))
    }

    private var appleItems: [String: MenuBarItem] {
        [
            "module:Battery": module("Battery"), "module:WiFi": module("WiFi"), "module:Clock": module("Clock"),
            "siri": MenuBarItem(key: k("siri"), owner: .app(systemUIServer, name: "SystemUIServer")),
        ]
    }

    private let appleOrder = ["h1", "D", "v1", "module:Battery", "module:WiFi", "module:Clock"]

    private func appleHarness(
        _ order: [String]? = nil, drawn: [String]? = nil, uncertain: Set<String> = [], withController: Bool = true,
        withDivider: Bool = true
    ) -> Harness {
        Harness(
            order: order ?? appleOrder, sections: ["h1": .hidden, "v1": .visible], items: appleItems,
            pinned: ["module:Clock"], drawn: drawn, uncertain: uncertain, withController: withController,
            withDivider: withDivider)
    }

    @Test func movingAModuleAssignsItAndPlacesItsKeyAtTheDivider() async {
        let h = appleHarness()

        #expect(await h.actions.move(.systemItem(wifi), to: .hidden) == .done)

        #expect(h.layout.section(of: wifi) == .hidden)
        #expect(
            await h.writes().map(\.target) == [ks("h1", "module:WiFi", "D", "v1", "module:Battery", "module:Clock")])
    }

    // Review focus 3: Wi-Fi is drawn with its identifier but the order file has no entry of its own, so its key is
    // uncertain. It is assigned, and nothing is written: Battery's entry can't be moved in its place.
    @Test func movingAModuleWithAnUncertainKeyAssignsItWithoutAnOrderWrite() async {
        let h = appleHarness(uncertain: ["module:WiFi"])

        #expect(await h.actions.move(.systemItem(wifi), to: .hidden) == .sectionChangedInPlace(.hidden, .uncertainKey))

        #expect(h.layout.section(of: wifi) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func aHiddenModuleWithACertainKeyMovesLikeAHiddenAppsItem() async {
        var items = appleItems
        items["module:WiFi"] = module("WiFi", at: nil)
        let h = Harness(
            order: ["module:WiFi", "h1", "D", "v1", "module:Clock"], sections: ["h1": .hidden, "v1": .visible],
            items: items, pinned: ["module:Clock"], drawn: ["h1", "D", "v1", "module:Clock"])
        h.state.assign(wifi, to: .hidden)

        #expect(await h.actions.move(.systemItem(wifi), to: .visible) == .saved)

        #expect(h.layout.section(of: wifi) == .visible)
        #expect(await h.writes().map(\.target) == [ks("h1", "D", "module:WiFi", "v1", "module:Clock")])
    }

    @Test func droppingAnUnassignedModuleWithinVisibleRecordsVisibleThenMovesIt() async {
        let h = appleHarness()
        #expect(h.layout.section(of: wifi) == nil)

        #expect(await h.actions.drop(k("module:WiFi"), to: .visible, before: k("v1")) == .done)

        #expect(h.layout.section(of: wifi) == .visible)
        #expect(
            await h.writes().map(\.target) == [ks("h1", "D", "module:WiFi", "v1", "module:Battery", "module:Clock")])
    }

    @Test func droppingUnassignedSiriWithinVisibleAssignsItsOwnerVisibleWhateverTheDefault() async {
        let h = appleHarness(["h1", "D", "v1", "siri", "module:Clock"])
        h.state.setDefaultSection(.hidden)

        #expect(await h.actions.drop(k("siri"), to: .visible, before: k("v1")) == .done)

        #expect(h.layout.section(of: systemUIServer) == .visible)
        #expect(await h.writes().map(\.target) == [ks("h1", "D", "siri", "v1", "module:Clock")])
    }

    // Catches an assigned Apple owner whose item is off the bar showing as its process name, "SystemUIServer: hidden".
    @Test func assigningAnAppleOwnerRecordsItsItemsNameNotItsProcessName() async {
        let siri = "status:com.apple.systemuiserver::Siri"
        let h = Harness(
            order: ["h1", "D", "v1", siri], sections: ["h1": .hidden, "v1": .visible],
            items: [siri: MenuBarItem(key: k(siri), owner: .app(systemUIServer, name: "SystemUIServer"))])

        _ = await h.actions.move(.app(systemUIServer), to: .hidden)

        #expect(h.layout.apps[systemUIServer]?.name == "Siri")
    }

    @Test func aRefusedDropOfAnUnassignedAppleItemWithinItsRowRecordsNothing() async {
        let uncertain = appleHarness(uncertain: ["module:WiFi"])
        #expect(await uncertain.actions.drop(k("module:WiFi"), to: .visible, before: k("v1")) == .unavailable(apart))
        #expect(uncertain.layout.section(of: wifi) == nil)

        let noController = appleHarness(withController: false)
        #expect(await noController.actions.drop(k("module:WiFi"), to: .visible, before: k("v1"))
            == .unavailable(noReordering))
        #expect(noController.layout.section(of: wifi) == nil)

        let noDivider = appleHarness(withDivider: false)
        #expect(await noDivider.actions.drop(k("module:WiFi"), to: .visible, before: k("v1")) == .unavailable(noIcon))
        #expect(noDivider.layout.section(of: wifi) == nil)
    }

    @Test func movingThePinnedClockToAnotherSectionChangesOnlyItsSection() async {
        let h = appleHarness()

        #expect(await h.actions.move(.systemItem(clock), to: .hidden) == .sectionChangedInPlace(.hidden, .pinned))
        #expect(await h.actions.drop(k("module:Clock"), to: .alwaysHidden, before: k("h1"))
            == .sectionChangedInPlace(.alwaysHidden, .pinned))

        #expect(h.layout.section(of: clock) == .alwaysHidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func movingThePinnedClockWithinItsRowIsRefusedWithoutAWrite() async {
        let h = appleHarness()

        #expect(await h.actions.drop(k("module:Clock"), to: .visible, before: k("v1")) == .unavailable(pinnedText))
        #expect(await h.actions.drop(k("module:Clock"), to: .visible, before: nil) == .unavailable(pinnedText))

        #expect(h.layout.section(of: clock) == nil)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func theNoticesForAPinnedItemSayWhyItStayed() {
        #expect(LayoutOutcome.sectionChangedInPlace(.hidden, .pinned).notice == LayoutNotice(
            text: "Moved to Hidden. macOS keeps this item at the right end of the bar, so it stays where it is.",
            isProblem: false))
        #expect(LayoutOutcome.unavailable(pinnedText).notice == LayoutNotice(text: pinnedText, isProblem: true))
    }

    // Review focus 1: an Apple item the user hasn't assigned has no section for the planner.
    @Test func tidyLeavesAnUnassignedAppleItemLeftOfTheDivider() async {
        let h = appleHarness(["module:WiFi", "siri", "h1", "D", "v1"])

        #expect(h.menuBar.misplaced(layout: h.layout).isEmpty)
        #expect(await h.actions.tidy() == .unchanged)
        #expect(await h.writes().isEmpty)
    }

    @Test func tidyMovesAnAppleItemOnceItIsAssignedVisible() async {
        let h = appleHarness(["module:WiFi", "siri", "h1", "D", "v1"])
        h.state.assign(wifi, to: .visible)

        #expect(h.menuBar.misplaced(layout: h.layout) == [k("module:WiFi")])
        #expect(await h.actions.tidy() == .done)
        #expect(await h.writes().map(\.target) == [ks("siri", "h1", "D", "module:WiFi", "v1")])
    }
}
