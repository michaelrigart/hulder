import Foundation
import Testing
@testable import HulderCore

@MainActor
struct LayoutActionsTests {
    private let noIcon = "Hulder's icon isn't on the menu bar."
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
        let actions: LayoutActions

        /// `order` lists item keys; each key `x` belongs to app `com.example.x` unless `owners` says
        /// otherwise. Every app in `sections` is recorded and assigned. "D" is Hulder's own icon.
        init(
            order: [String],
            sections: [String: Section],
            owners: [String: String] = [:],
            drawn: [String]? = nil,
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
                    if key == "D" {
                        return MenuBarItem(
                            key: ItemKey(raw: key), owner: .app(AppID("com.michaelrigart.hulder"), name: "Hulder"))
                    }
                    let id = owners[key] ?? key
                    return MenuBarItem(
                        key: ItemKey(raw: key), owner: .app(AppID("com.example.\(id)"), name: id.uppercased()))
                },
                stale: [])
            let bar = BarOrder(keys: order.map { ItemKey(raw: $0) }, pinned: [])
            menuBar.order = bar
            menuBar.divider = withDivider ? ItemKey(raw: "D") : nil
            orderStore = FakeOrderStore(
                order: bar, drawn: Set((drawn ?? order).map { ItemKey(raw: $0) }), script: script)
            let controller = OrderController(store: orderStore, clock: clock)
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

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .done)

        #expect(h.layout.section(of: app("v1")) == .hidden)
        let expected = try #require(OrderPlanner.placeAtDivider(ks("v1"), section: .hidden, in: h.context()))
        #expect(expected.target == ks("h1", "h2", "v1", "D", "v2"))
        #expect(await h.writes() == [expected])
    }

    @Test func moveWithoutReorderingStillAssigns() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .done)

        #expect(h.layout.section(of: app("v1")) == .hidden)
        #expect(await h.orderStore.log.isEmpty)
    }

    @Test func moveToTheSameSectionWithoutReorderingIsUnchanged() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)

        #expect(await h.actions.move(app: app("v1"), to: .visible) == .unchanged)
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

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .unavailable(noIcon))

        #expect(h.layout.section(of: app("v1")) == .hidden)
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

        #expect(await h.actions.move(app: app("x"), to: .alwaysHidden) == .done)

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

        #expect(await h.actions.move(app: ownApp, to: .hidden) == .unchanged)
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

        #expect(await h.actions.move(app: app("v1"), to: .visible) == .unchanged)
        #expect(await h.writes().isEmpty)
    }

    @Test func aSectionChangeWhoseOrderIsAlreadyRightIsDone() async {
        // h2 is recorded as Visible but already sits left of the divider, where Hidden items go.
        let h = Harness(order: standard, sections: ["h1": .hidden, "h2": .visible, "v1": .visible, "v2": .visible])

        #expect(await h.actions.move(app: app("h2"), to: .hidden) == .done)

        #expect(h.layout.section(of: app("h2")) == .hidden)
        #expect(await h.writes().isEmpty)
    }

    @Test func unconfirmedOrderRecordsAFailure() async throws {
        let h = Harness(order: standard, sections: standardSections, script: .init(writeEffect: .silent))
        let move = Task { await h.actions.move(app: app("v1"), to: .hidden) }
        try #require(await waitUntil { h.clock.sleeperCount == 1 })

        await h.clock.advance(by: .seconds(3))

        #expect(await move.value == .failed(.orderUnconfirmed))
        #expect(h.menuBar.lastFailure == .orderUnconfirmed)
    }

    @Test func anOrderThatKeepsChangingRecordsAGaveUpFailure() async {
        let h = Harness(order: standard, sections: standardSections, script: .init(staleWrites: 2))

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .failed(.orderGaveUp))
        #expect(h.menuBar.lastFailure == .orderGaveUp)
    }

    @Test func aWriteErrorRecordsAWriteFailure() async {
        let h = Harness(order: standard, sections: standardSections, script: .init(writeError: .io))

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .failed(.orderWriteFailed))
        #expect(h.menuBar.lastFailure == .orderWriteFailed)
    }

    @Test func anUnavailableOrderStoreIsPassedOnWithoutAFailure() async {
        let h = Harness(order: standard, sections: standardSections, script: .init(readError: .noAccess))

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .unavailable("No access to the order file"))
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

    @Test func firstSightingIsPlacedAtTheDividerOfItsSection() async throws {
        let h = Harness(
            order: ["h1", "D", "v1", "n1"], sections: ["h1": .hidden, "v1": .visible], owners: ["n1": "n"])
        h.state.setDefaultSection(.hidden)
        let added = h.state.recordSightings([(app("n"), "N")], at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(added == [app("n")])

        await h.actions.placeFirstSighting(app("n"))

        #expect(h.layout.section(of: app("n")) == .hidden)
        #expect(await h.writes().map(\.target) == [ks("h1", "n1", "D", "v1")])
    }

    @Test func firstSightingWithoutAControllerOrDividerDoesNothing() async {
        let noController = Harness(order: standard, sections: standardSections, withController: false)
        let noDivider = Harness(order: standard, sections: standardSections, withDivider: false)

        await noController.actions.placeFirstSighting(app("v1"))
        await noDivider.actions.placeFirstSighting(app("v1"))

        #expect(await noDivider.orderStore.log.isEmpty)
        #expect(noController.menuBar.failures.isEmpty && noDivider.menuBar.failures.isEmpty)
    }

    @Test func theOrderControllerCanBeSetLater() async {
        let h = Harness(order: standard, sections: standardSections, withController: false)
        let controller = OrderController(store: h.orderStore, clock: h.clock)

        h.actions.setOrderController(controller)

        #expect(await h.actions.move(app: app("v1"), to: .hidden) == .done)
        #expect(await h.writes().count == 1)
    }
}
