import Foundation
import Testing
@testable import HulderCore

@MainActor
struct MenuBarModelTests {
    private let divider = ItemKey(raw: "D")

    private func app(_ id: String) -> AppID { AppID("com.example.\(id)") }

    private func item(_ key: String, app id: String, at position: Double? = nil) -> MenuBarItem {
        MenuBarItem(key: ItemKey(raw: key), owner: .app(app(id), name: id.uppercased()), barPosition: position)
    }

    private func layout(_ sections: [String: Section]) -> Layout {
        var layout = Layout()
        let now = Date(timeIntervalSince1970: 0)
        for (id, section) in sections {
            _ = layout.recordSighting(app(id), name: id.uppercased(), at: now)
            layout.assign(app(id), to: section)
        }
        return layout
    }

    private func keys(_ entries: [LayoutEntry]?) -> [String] {
        (entries ?? []).map {
            switch $0 {
            case .item(let item): item.key.raw
            case .absentApp(let app, _): "absent:" + app.bundleID
            }
        }
    }

    @Test func rowsAreInBarOrderWithAbsentAppsLast() {
        let model = MenuBarModel()
        model.divider = divider
        model.inventory = InventorySnapshot(
            items: [item("v1", app: "v1", at: 300), item("h1", app: "h1", at: 100), item("h2", app: "h2", at: 200)],
            stale: [])
        // The order wins over the positions.
        model.order = BarOrder(keys: ["h2", "h1", "D", "v1"].map { ItemKey(raw: $0) }, pinned: [])

        let rows = model.rows(layout: layout(["v1": .visible, "h1": .hidden, "h2": .hidden, "zed": .hidden, "abe": .hidden]))

        #expect(keys(rows[.hidden]) == ["h2", "h1", "absent:com.example.abe", "absent:com.example.zed"])
        #expect(keys(rows[.visible]) == ["v1"])
        #expect(keys(rows[.alwaysHidden]).isEmpty)
    }

    @Test func rowsFallBackToBarPositionAcrossOwners() {
        let model = MenuBarModel()
        model.inventory = InventorySnapshot(
            items: [item("A2", app: "a", at: 300), item("B1", app: "b", at: 200), item("A1", app: "a", at: 100)],
            stale: [])

        let rows = model.rows(layout: layout(["a": .visible, "b": .visible]))

        #expect(keys(rows[.visible]) == ["A1", "B1", "A2"])
    }

    @Test func undrawnItemsComeLastInInventoryOrder() {
        let model = MenuBarModel()
        model.inventory = InventorySnapshot(
            items: [item("u1", app: "a"), item("d1", app: "b", at: 50), item("u2", app: "c")], stale: [])

        let rows = model.rows(layout: layout(["a": .visible, "b": .visible, "c": .visible]))

        #expect(keys(rows[.visible]) == ["d1", "u1", "u2"])
    }

    @Test func rowsLeaveOutTheDividerManagedItemsAndUnresolvedOwners() {
        let model = MenuBarModel()
        model.divider = divider
        model.inventory = InventorySnapshot(
            items: [
                MenuBarItem(key: divider, owner: .app(AppID("com.michaelrigart.hulder"), name: "Hulder")),
                MenuBarItem(key: ItemKey(raw: "clock"), owner: .unresolved(processName: "clock"), isManagedByMacOS: true),
                MenuBarItem(key: ItemKey(raw: "ghost"), owner: .unresolved(processName: "ghost")),
                item("v1", app: "v1"),
            ],
            stale: [])

        let rows = model.rows(layout: layout(["v1": .visible]))

        #expect(keys(rows[.visible]) == ["v1"])
    }

    @Test func rowsLeaveOutEveryItemOfHulderNotJustTheDivider() {
        let model = MenuBarModel()
        model.divider = divider
        let hulder = AppID("com.michaelrigart.hulder")
        model.inventory = InventorySnapshot(
            items: [
                MenuBarItem(key: divider, owner: .app(hulder, name: "Hulder")),
                MenuBarItem(key: ItemKey(raw: "other"), owner: .app(hulder, name: "Hulder")),
                item("v1", app: "v1"),
            ],
            stale: [])

        let rows = model.rows(layout: layout(["v1": .visible]))

        #expect(keys(rows[.visible]) == ["v1"])
        #expect(model.readOnlyItems().isEmpty)
    }

    @Test func everyRecordedFailureCountsEvenAnIdenticalOne() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)

        model.recordFailure(.settingsNotSaved, at: date)
        model.recordFailure(.settingsNotSaved, at: date)

        #expect(model.recordedFailureCount == 2)
    }

    @Test func failuresKeepTheNewestTen() {
        let model = MenuBarModel()
        let kinds = (0..<12).map { FailureKind.allCases[$0 % FailureKind.allCases.count] }
        for (index, kind) in kinds.enumerated() {
            model.recordFailure(kind, at: Date(timeIntervalSince1970: Double(index)))
        }

        #expect(kinds.count == 12)
        #expect(model.failures.count == 10)
        #expect(model.failures.first?.date == Date(timeIntervalSince1970: 2))
        #expect(model.lastFailure == kinds[11])
    }

    @Test func failureMessagesAreTheFixedTexts() {
        #expect(FailureKind.hidingRejected.message == "macOS refused to hide items.")
        #expect(FailureKind.hidingTimedOut.message == "Hiding didn't take effect: macOS didn't answer in time.")
        #expect(FailureKind.hidingUnavailable.message == "Hiding isn't available on this version of macOS.")
        #expect(FailureKind.orderUnconfirmed.message == "The new order didn't show up on the menu bar.")
        #expect(FailureKind.orderGaveUp.message == "The menu bar order kept changing, so Hulder stopped.")
        #expect(FailureKind.orderWriteFailed.message == "Hulder couldn't save the new order.")
        #expect(FailureKind.settingsNotSaved.message == "Hulder couldn't save its settings.")
    }

    @Test func misplacedIsEmptyWithoutAnOrder() {
        let model = MenuBarModel()
        model.divider = divider
        model.inventory = InventorySnapshot(items: [item("h1", app: "h1")], stale: [])

        #expect(model.misplaced(layout: layout(["h1": .hidden])).isEmpty)
    }

    private var mixedInventory: [MenuBarItem] {
        [
            MenuBarItem(key: divider, owner: .app(AppID("com.michaelrigart.hulder"), name: "Hulder"), barPosition: 10),
            MenuBarItem(key: ItemKey(raw: "ghost"), owner: .unresolved(processName: "ghost"), barPosition: 300),
            item("v1", app: "v1", at: 20),
            MenuBarItem(
                key: ItemKey(raw: "clock"), owner: .unresolved(processName: "clock"), isManagedByMacOS: true,
                barPosition: 400),
            MenuBarItem(
                key: ItemKey(raw: "siri"), owner: .app(AppID("com.apple.siri"), name: "Siri"), isManagedByMacOS: true),
        ]
    }

    @Test func readOnlyItemsAreManagedAndUnresolvedItemsByPositionWithoutHulder() {
        let model = MenuBarModel()
        model.divider = divider
        model.inventory = InventorySnapshot(items: mixedInventory, stale: [])

        let items = model.readOnlyItems()

        #expect(items.map(\.key.raw) == ["ghost", "clock", "siri"])
    }

    @Test func readOnlyItemsFollowTheOrderFileWhenThereIsOne() {
        let model = MenuBarModel()
        model.divider = divider
        model.inventory = InventorySnapshot(items: mixedInventory, stale: [])
        model.order = BarOrder(keys: ["clock", "D", "ghost", "v1"].map { ItemKey(raw: $0) }, pinned: [])

        let items = model.readOnlyItems()

        #expect(items.map(\.key.raw) == ["clock", "ghost", "siri"])
    }

    // MARK: - The failure line

    @Test func aHidingFailureShowsUntilALaterApply() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)

        model.recordConcealment(.failed(.timedOut), at: date)
        #expect(model.hidingFailure == .hidingTimedOut)

        model.recordConcealment(.applied, at: date)
        #expect(model.hidingFailure == nil)
    }

    @Test func aNewerHidingFailureReplacesAnOlderOne() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)

        model.recordConcealment(.failed(.timedOut), at: date)
        model.recordConcealment(.failed(.rejected), at: date)

        #expect(model.hidingFailure == .hidingRejected)
    }

    @Test func aFailureAfterAnApplyShowsAgain() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)
        model.recordConcealment(.failed(.rejected), at: date)
        model.recordConcealment(.applied, at: date)

        model.recordConcealment(.failed(.unavailable("No.")), at: date)

        #expect(model.hidingFailure == .hidingUnavailable)
    }

    @Test func aSupersededOutcomeLeavesTheHidingFailure() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)
        model.recordConcealment(.failed(.rejected), at: date)

        model.recordConcealment(.superseded, at: date)

        #expect(model.hidingFailure == .hidingRejected)
    }

    @Test func goingBackToTheAppliedPlanAfterAFailureClearsTheLine() {
        // A applied, B failed, then A requested again: the bar already matches, so the controller says
        // unchanged and the failure is no longer true.
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)
        model.recordConcealment(.applied, at: date)
        model.recordConcealment(.failed(.timedOut), at: date)
        #expect(model.hidingFailure == .hidingTimedOut)

        model.recordConcealment(.unchanged, at: date)

        #expect(model.hidingFailure == nil)
        #expect(model.failures.map(\.kind) == [.hidingTimedOut])
    }

    @Test func orderAndSettingsFailuresAreNotTheHidingFailure() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)

        model.recordFailure(.orderWriteFailed, at: date)
        model.recordFailure(.settingsNotSaved, at: date)

        #expect(model.hidingFailure == nil)
        #expect(model.lastFailure == .settingsNotSaved)
    }

    @Test func anOrderFailureDoesNotHideTheHidingFailure() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)
        model.recordConcealment(.failed(.timedOut), at: date)

        model.recordFailure(.orderGaveUp, at: date)

        #expect(model.hidingFailure == .hidingTimedOut)
    }

    @Test func aConcealmentFailureIsRecordedInTheFailureList() {
        let model = MenuBarModel()
        let date = Date(timeIntervalSince1970: 0)

        model.recordConcealment(.failed(.rejected), at: date)
        model.recordConcealment(.failed(.timedOut), at: date)
        model.recordConcealment(.failed(.unavailable("No.")), at: date)
        model.recordConcealment(.applied, at: date)

        #expect(model.failures.map(\.kind) == [.hidingRejected, .hidingTimedOut, .hidingUnavailable])
        #expect(model.recordedFailureCount == 3)
    }

    // MARK: - Apple's items

    private let wifi = SystemItemID(moduleName: "WiFi")
    private let agent = ItemOwner.app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent")

    private func appleModel(wifiAt position: Double? = 10) -> MenuBarModel {
        let model = MenuBarModel()
        model.inventory = InventorySnapshot(
            items: [
                MenuBarItem(
                    key: ItemKey(raw: "module:WiFi"), owner: agent, isManagedByMacOS: true, barPosition: position,
                    systemItem: wifi),
                MenuBarItem(
                    key: ItemKey(raw: "siri"), owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer"),
                    barPosition: 20),
                MenuBarItem(
                    key: ItemKey(raw: "module:FocusModes"), owner: agent, isManagedByMacOS: true, barPosition: 30),
                item("h1", app: "h1", at: 5),
            ],
            stale: [])
        return model
    }

    @Test func unassignedAppleItemsAreInTheVisibleRowWhateverTheDefault() {
        var layout = layout(["h1": .hidden])
        layout.defaultSection = .hidden

        let rows = appleModel().rows(layout: layout)

        #expect(keys(rows[.visible]) == ["module:WiFi", "siri"])
        #expect(keys(rows[.hidden]) == ["h1"])
    }

    @Test func aModuleAssignedHiddenIsInTheHiddenRowAlsoWhenHiddenFromTheBar() {
        var layout = layout(["h1": .hidden])
        layout.assign(wifi, to: .hidden)

        #expect(keys(appleModel().rows(layout: layout)[.hidden]) == ["h1", "module:WiFi"])
        #expect(keys(appleModel(wifiAt: nil).rows(layout: layout)[.hidden]) == ["h1", "module:WiFi"])
    }

    @Test func focusIsOnlyReadOnly() {
        let model = appleModel()

        #expect(model.readOnlyItems().map(\.key.raw) == ["module:FocusModes"])
        #expect(!Section.allCases.contains { keys(model.rows(layout: Layout())[$0]).contains("module:FocusModes") })
    }
}
