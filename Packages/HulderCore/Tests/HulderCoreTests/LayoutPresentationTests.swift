import Foundation
import Testing
@testable import HulderCore

@MainActor
struct LayoutPresentationTests {
    private func key(_ raw: String) -> ItemKey { ItemKey(raw: raw) }

    /// Drawn on the bar unless `position` is nil.
    private func item(
        _ raw: String, name: String = "Alpha", description: String? = nil, title: String? = nil,
        managed: Bool = false, owner: ItemOwner? = nil, at position: Double? = 10
    ) -> MenuBarItem {
        MenuBarItem(
            key: key(raw), owner: owner ?? .app(AppID("com.example.alpha"), name: name), description: description,
            title: title, isManagedByMacOS: managed, barPosition: position)
    }

    // MARK: - Sections

    @Test func sectionsRunFromHiddenToVisibleAsTheBarDoes() {
        #expect(Section.displayOrder == [.alwaysHidden, .hidden, .visible])
    }

    @Test func aSectionsNeighboursAreTheNextSectionsLeftAndRight() {
        #expect(Section.alwaysHidden.neighbour(.left) == nil)
        #expect(Section.alwaysHidden.neighbour(.right) == .hidden)
        #expect(Section.hidden.neighbour(.left) == .alwaysHidden)
        #expect(Section.hidden.neighbour(.right) == .visible)
        #expect(Section.visible.neighbour(.left) == .hidden)
        #expect(Section.visible.neighbour(.right) == nil)
    }

    // MARK: - Neighbours within a row

    @Test func anItemInTheMiddleHasBothNeighboursAndTheItemAfterTheRightOne() {
        let entries: [LayoutEntry] = [.item(item("a")), .item(item("b")), .item(item("c")), .item(item("d"))]

        let neighbours = RowNeighbours.byItem(in: entries)

        #expect(neighbours[key("b")] == RowNeighbours(left: key("a"), right: key("c"), afterRight: key("d")))
    }

    @Test func theEndsOfARowHaveNoNeighbourOnThatSide() {
        let entries: [LayoutEntry] = [.item(item("a")), .item(item("b")), .item(item("c"))]

        let neighbours = RowNeighbours.byItem(in: entries)

        #expect(neighbours[key("a")] == RowNeighbours(left: nil, right: key("b"), afterRight: key("c")))
        #expect(neighbours[key("c")] == RowNeighbours(left: key("b"), right: nil, afterRight: nil))
    }

    @Test func theItemBeforeTheLastHasNoItemAfterItsRightNeighbour() {
        let entries: [LayoutEntry] = [.item(item("a")), .item(item("b"))]

        #expect(RowNeighbours.byItem(in: entries)[key("a")] == RowNeighbours(left: nil, right: key("b"), afterRight: nil))
    }

    @Test func aSingleItemHasNoNeighbours() {
        let neighbours = RowNeighbours.byItem(in: [.item(item("a"))])

        #expect(neighbours == [key("a"): RowNeighbours(left: nil, right: nil, afterRight: nil)])
    }

    @Test func absentAppsAreNotNeighboursAndHaveNoEntry() {
        let entries: [LayoutEntry] = [.item(item("a")), .item(item("b")), .absentApp(AppID("com.example.z"), name: "Z")]

        let neighbours = RowNeighbours.byItem(in: entries)

        #expect(neighbours[key("b")]?.right == nil)
        #expect(neighbours.count == 2)
    }

    @Test func movingLeftDropsBeforeTheLeftNeighbourAndRightBeforeTheItemAfterTheRightOne() {
        let neighbours = RowNeighbours(left: key("a"), right: key("c"), afterRight: key("d"))

        #expect(neighbours.dropPoint(moving: .left) == .before(key("a")))
        #expect(neighbours.dropPoint(moving: .right) == .before(key("d")))
    }

    @Test func movingRightOnTheSecondLastItemDropsAtTheEndOfTheRow() {
        let neighbours = RowNeighbours(left: key("a"), right: key("c"), afterRight: nil)

        #expect(neighbours.dropPoint(moving: .right) == .endOfRow)
        #expect(neighbours.dropPoint(moving: .right)?.anchor == nil)
    }

    @Test func aDropPointAnchorsOnItsItem() {
        #expect(RowNeighbours.DropPoint.before(key("a")).anchor == key("a"))
    }

    @Test func thereIsNoMoveBeyondTheEndsOfARow() {
        let first = RowNeighbours(left: nil, right: key("b"), afterRight: nil)
        let last = RowNeighbours(left: key("b"), right: nil, afterRight: nil)
        let only = RowNeighbours(left: nil, right: nil, afterRight: nil)

        #expect(first.dropPoint(moving: .left) == nil)
        #expect(last.dropPoint(moving: .right) == nil)
        #expect(only.dropPoint(moving: .left) == nil)
        #expect(only.dropPoint(moving: .right) == nil)
    }

    // MARK: - Labels

    @Test func anItemsLabelIsItsAppNameAndItsDescription() {
        #expect(item("a", description: "Sync status", title: "Alpha").label == "Alpha: Sync status")
    }

    @Test func anItemsLabelFallsBackToTheTitleWhenTheDescriptionIsMissingOrEmpty() {
        #expect(item("a", description: nil, title: "Alpha item").label == "Alpha: Alpha item")
        #expect(item("a", description: "", title: "Alpha item").label == "Alpha: Alpha item")
    }

    @Test func anItemWithNeitherIsLabelledWithItsAppNameAlone() {
        #expect(item("a").label == "Alpha")
    }

    @Test func anUnresolvedOwnerIsLabelledWithItsProcessName() {
        #expect(item("p", description: "Tick", owner: .unresolved(processName: "ticker")).label == "ticker: Tick")
    }

    private let dateStyle = Date.FormatStyle(
        date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"),
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!)

    private func layoutWithAbsentApp() -> Layout {
        var layout = Layout()
        _ = layout.recordSighting(AppID("com.example.zed"), name: "Zed", at: Date(timeIntervalSince1970: 0))
        return layout
    }

    @Test func anAbsentAppThatIsNotRunningSaysSoWithTheDayItWasLastSeen() {
        let model = MenuBarModel()
        let entry = LayoutEntry.absentApp(AppID("com.example.zed"), name: "Zed")

        let label = model.label(of: entry, layout: layoutWithAbsentApp(), dateStyle: dateStyle)

        #expect(label == "Zed: not running, last seen Jan 1, 1970")
    }

    @Test func anAbsentAppThatIsRunningIsNotOnTheMenuBar() {
        let model = MenuBarModel()
        model.running = [AppID("com.example.zed")]
        let entry = LayoutEntry.absentApp(AppID("com.example.zed"), name: "Zed")

        let label = model.label(of: entry, layout: layoutWithAbsentApp(), dateStyle: dateStyle)

        #expect(label == "Zed: not on the menu bar")
    }

    private func runningAbsentApp(in section: Section, state: RevealState) -> String {
        var layout = layoutWithAbsentApp()
        layout.assign(AppID("com.example.zed"), to: section)
        let model = MenuBarModel()
        model.running = [AppID("com.example.zed")]
        model.revealState = state
        return model.label(
            of: .absentApp(AppID("com.example.zed"), name: "Zed"), layout: layout, dateStyle: dateStyle)
    }

    @Test func aRunningAppWhoseSectionTheRevealStateHidesIsHidden() {
        #expect(runningAbsentApp(in: .hidden, state: .hidden) == "Zed: hidden")
        #expect(runningAbsentApp(in: .alwaysHidden, state: .hidden) == "Zed: hidden")
        #expect(runningAbsentApp(in: .alwaysHidden, state: .revealed) == "Zed: hidden")
    }

    @Test func aRunningAppWhoseSectionIsShownIsNotOnTheMenuBar() {
        #expect(runningAbsentApp(in: .visible, state: .hidden) == "Zed: not on the menu bar")
        #expect(runningAbsentApp(in: .hidden, state: .revealed) == "Zed: not on the menu bar")
        #expect(runningAbsentApp(in: .alwaysHidden, state: .revealedAll) == "Zed: not on the menu bar")
    }

    @Test func aPresentItemKeepsItsPlainLabelWhateverIsRunning() {
        let model = MenuBarModel()

        #expect(model.label(of: .item(item("a", description: "Sync")), layout: Layout(), dateStyle: dateStyle) == "Alpha: Sync")
    }

    @Test func anUnmanagedAppleItemIsNamedByItselfAndSaysItIsPartOfMacOS() {
        let model = MenuBarModel()
        let siri = item("status:com.apple.systemuiserver::Siri", name: "SystemUIServer", owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer"))
        let input = item("status:com.apple.TextInputMenuAgent::Item-0", name: "TextInputMenuAgent", owner: .app(AppID("com.apple.TextInputMenuAgent"), name: "TextInputMenuAgent"))
        let wifi = MenuBarItem(
            key: key("module:WiFi"), owner: .app(AppID("com.apple.controlcenter"), name: "Control Center"),
            isManagedByMacOS: true, barPosition: 10, systemItem: SystemItemID(moduleName: "WiFi"))

        #expect(siri.label == "Siri")
        #expect(input.label == "Input Menu")
        #expect(wifi.label == "Wi-Fi")
        #expect(model.label(of: .item(siri), layout: Layout(), dateStyle: dateStyle) == "Siri, part of macOS")
        #expect(model.label(of: .item(input), layout: Layout(), dateStyle: dateStyle) == "Input Menu, part of macOS")
        #expect(model.label(of: .item(wifi), layout: Layout(), dateStyle: dateStyle) == "Wi-Fi, part of macOS")
    }

    // Catches a hidden module, or a hidden app's item, listed in its row with nothing to say it is off the bar.
    @Test func anItemThatIsNotDrawnIsMarkedHidden() {
        let model = MenuBarModel()
        let wifi = MenuBarItem(
            key: key("module:WiFi"), owner: .app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent"),
            isManagedByMacOS: true, systemItem: SystemItemID(moduleName: "WiFi"))

        #expect(model.label(of: .item(wifi), layout: Layout(), dateStyle: dateStyle) == "Wi-Fi, part of macOS, hidden")
        #expect(model.label(of: .item(item("a", description: "Sync", at: nil)), layout: Layout(), dateStyle: dateStyle)
            == "Alpha: Sync, hidden")
    }

    // Catches Apple's items showing only their owner's icon, with nothing in the row to tell them apart.
    @Test func appleItemsHaveARowTitleAndAppItemsDoNot() {
        func module(_ name: String) -> MenuBarItem {
            MenuBarItem(
                key: key("module:\(name)"), owner: .app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent"),
                isManagedByMacOS: true, systemItem: SystemItemID(moduleName: name))
        }
        let siri = item("status:com.apple.systemuiserver::Siri", name: "SystemUIServer", owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer"))
        let input = item("status:com.apple.TextInputMenuAgent::Item-0", name: "TextInputMenuAgent", owner: .app(AppID("com.apple.TextInputMenuAgent"), name: "TextInputMenuAgent"))

        #expect(module("WiFi").rowTitle == "Wi-Fi")
        #expect(module("Battery").rowTitle == "Battery")
        #expect(module("Clock").rowTitle == "Clock")
        #expect(module("BentoBox").rowTitle == "Control Center")
        #expect(siri.rowTitle == "Siri")
        #expect(input.rowTitle == "Input Menu")
        #expect(item("a", description: "Sync").rowTitle == nil)
        #expect(item("module:Display", managed: true).rowTitle == nil)
    }

    // Catches Apple's background agents showing a generic app icon, and an app's item losing its own icon.
    @Test func appleItemsHaveASymbolAndAppItemsDoNot() {
        func module(_ name: String) -> MenuBarItem {
            MenuBarItem(
                key: key("module:\(name)"), owner: .app(AppID("com.apple.MenuBarAgent"), name: "MenuBarAgent"),
                isManagedByMacOS: true, systemItem: SystemItemID(moduleName: name))
        }
        let siri = item("status:com.apple.systemuiserver::Siri", name: "SystemUIServer", owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer"))
        let input = item("status:com.apple.TextInputMenuAgent::Item-0", name: "TextInputMenuAgent", owner: .app(AppID("com.apple.TextInputMenuAgent"), name: "TextInputMenuAgent"))
        let other = item("status:com.apple.systemuiserver::Other", name: "SystemUIServer", owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer"))

        #expect(module("WiFi").symbolName == "wifi")
        #expect(module("BentoBox").symbolName == "switch.2")
        #expect(module("Mystery").symbolName == "menubar.rectangle")
        #expect(item("module:Display", managed: true).symbolName == nil)
        #expect(siri.symbolName == "siri")
        #expect(input.symbolName == "keyboard")
        #expect(other.symbolName == "menubar.rectangle")
        #expect(item("a", description: "Sync").symbolName == nil)
    }

    // Catches an assigned Apple owner with no item on the bar going back to its generic app icon.
    @Test func anAbsentAppleOwnerHasASymbolAndAnAbsentAppDoesNot() {
        let input = LayoutEntry.absentApp(AppID("com.apple.TextInputMenuAgent"), name: "TextInputMenuAgent")
        let systemUIServer = LayoutEntry.absentApp(AppID("com.apple.systemuiserver"), name: "SystemUIServer")
        let app = LayoutEntry.absentApp(AppID("com.example.alpha"), name: "Alpha")

        #expect(input.symbolName == "keyboard")
        #expect(systemUIServer.symbolName == "menubar.rectangle")
        #expect(app.symbolName == nil)
        #expect(LayoutEntry.item(item("status:com.apple.TextInputMenuAgent::Item-0", owner: .app(AppID("com.apple.TextInputMenuAgent"), name: "TextInputMenuAgent"))).symbolName == "keyboard")
    }

    // Catches the tooltip and the symbol disagreeing on what is part of macOS: a managed item with an app's owner
    // is not, and keeps its owner's icon.
    @Test func theTooltipAndTheSymbolAgreeOnWhatIsPartOfMacOS() {
        let model = MenuBarModel()
        let apple = AppID("com.apple.controlcenter")
        let items = [
            item("module:Display", managed: true),
            item("module:Display", managed: true, owner: .app(apple, name: "Control Center")),
            MenuBarItem(
                key: key("module:WiFi"), owner: .app(apple, name: "Control Center"), isManagedByMacOS: true,
                barPosition: 10, systemItem: SystemItemID(moduleName: "WiFi")),
            item("a", description: "Sync"),
            item("b", owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer")),
        ]

        for item in items {
            let tooltip = model.label(of: .item(item), layout: Layout(), dateStyle: dateStyle)
            #expect(tooltip.hasSuffix(", part of macOS") == item.isPartOfMacOS, "\(item.key.raw) \(item.owner.id)")
            #expect((item.symbolName != nil) == item.isPartOfMacOS, "\(item.key.raw) \(item.owner.id)")
        }
        #expect(items.map(\.isPartOfMacOS) == [false, true, true, false, true])
    }

    // MARK: - Read-only reasons

    @Test func focusExplainsThatMacOSHidesItWheneverHulderHidesAnything() {
        let focus = item("module:FocusModes", managed: true, owner: .app(AppID("com.apple.controlcenter"), name: "Control Center"))

        #expect(focus.readOnlyReason == "macOS hides Focus whenever Hulder hides anything")
    }

    @Test func aManagedModuleWithoutASystemItemCannotBeHidden() {
        let display = item("module:Display", managed: true, owner: .app(AppID("com.apple.controlcenter"), name: "Control Center"))

        #expect(display.readOnlyReason == "macOS doesn't let Hulder hide this item")
    }

    @Test func aManagedControlCenterItemStaysManagedByMacOS() {
        let item = item("status:com.apple.controlcenter::Item-0", managed: true, owner: .app(AppID("com.apple.controlcenter"), name: "Control Center"))

        #expect(item.readOnlyReason == "Managed by macOS")
    }

    @Test func anItemManagedByMacOSIsReportedAsSuchEvenWithAnUnresolvedOwner() {
        let managed = item("m", managed: true, owner: .unresolved(processName: "SystemUIServer"))

        #expect(managed.readOnlyReason == "Managed by macOS")
        #expect(item("s", managed: true).readOnlyReason == "Managed by macOS")
    }

    @Test func anUnresolvedOwnerHasNoAppBundle() {
        let ghost = item("g", owner: .unresolved(processName: "ghost"))

        #expect(ghost.readOnlyReason == "Hulder can't hide this: it has no app bundle")
    }

    // MARK: - Outcome notices

    @Test func aDoneOrUnchangedOutcomeNeedsNoLine() {
        #expect(LayoutOutcome.done.notice == nil)
        #expect(LayoutOutcome.unchanged.notice == nil)
    }

    @Test func aSavedOutcomeSaysWhenMacOSAppliesIt() {
        #expect(LayoutOutcome.saved.notice == LayoutNotice(
            text: "Saved. macOS applies it when these icons are shown.", isProblem: false))
    }

    @Test func aFailureShowsItsFixedMessageAsAProblem() {
        #expect(LayoutOutcome.failed(.orderWriteFailed).notice == LayoutNotice(
            text: "Hulder couldn't save the new order.", isProblem: true))
    }

    @Test func anUnavailableOutcomeShowsItsReasonAsAProblem() {
        #expect(LayoutOutcome.unavailable(LayoutActions.noReorderingText).notice == LayoutNotice(
            text: "Reordering needs access to the menu bar order file.", isProblem: true))
    }
}
