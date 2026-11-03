import Foundation
import Testing
@testable import HulderCore

struct LayoutTests {
    let t0 = noon()
    let a = AppID("com.example.a")
    let b = AppID("com.example.b")

    @Test func firstSightingAssignsDefaultSection() {
        var layout = Layout()
        layout.defaultSection = .hidden
        let first = layout.recordSighting(a, name: "A", at: t0)
        #expect(first)
        #expect(layout.section(of: a) == .hidden)

        layout.defaultSection = .visible
        let second = layout.recordSighting(a, name: "A2", at: t0.addingTimeInterval(5))
        #expect(!second)
        #expect(layout.section(of: a) == .hidden)
        #expect(layout.apps[a]?.name == "A2")
    }

    @Test func assignmentsSinceListsNewAppsAndChangedSectionsOnly() {
        var old = Layout()
        _ = old.recordSighting(a, name: "A", at: t0)
        _ = old.recordSighting(b, name: "B", at: t0)
        old.assign(b, to: .hidden)
        var layout = old
        let c = AppID("com.example.c")
        layout.assign(a, to: .alwaysHidden)
        _ = layout.recordSighting(c, name: "C", at: t0)
        _ = layout.recordSighting(b, name: "B2", at: t0.addingTimeInterval(5))

        let changes = layout.assignments(since: old)

        #expect(changes.map(\.app) == [a, c])
        #expect(changes.map(\.section) == [.alwaysHidden, .visible])
    }

    @Test func assignmentsSinceAnUnchangedLayoutIsEmptyAndAForgottenAppIsNotListed() {
        var old = Layout()
        _ = old.recordSighting(a, name: "A", at: t0)
        var layout = old
        #expect(layout.assignments(since: old).isEmpty)

        layout.forget(a)

        #expect(layout.assignments(since: old).isEmpty)
    }

    // Catches a module's assignment never reaching the log, which diffs the layouts through this.
    @Test func systemItemAssignmentsSinceListsNewAndChangedModulesOnly() {
        let (wifi, battery, clock) = (
            SystemItemID(moduleName: "WiFi"), SystemItemID(moduleName: "Battery"), SystemItemID(moduleName: "Clock"))
        var old = Layout()
        old.assign(wifi, to: .hidden)
        old.assign(clock, to: .visible)
        var layout = old
        #expect(layout.systemItemAssignments(since: old).isEmpty)

        layout.assign(wifi, to: .alwaysHidden)
        layout.assign(battery, to: .visible)
        layout.assign(clock, to: .visible)

        let changes = layout.systemItemAssignments(since: old)
        #expect(changes.map(\.item) == [battery, wifi])
        #expect(changes.map(\.section) == [.visible, .alwaysHidden])
    }

    @Test func aSightingOnTheSameDayLeavesLastSeenAlone() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        let before = layout

        _ = layout.recordSighting(a, name: "A", at: t0.addingTimeInterval(5))

        #expect(layout == before)
        #expect(layout.apps[a]?.lastSeen == t0)
    }

    @Test func aSightingOnALaterDayUpdatesLastSeen() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        let later = noon(days: 1)

        _ = layout.recordSighting(a, name: "A", at: later)

        #expect(layout.apps[a]?.lastSeen == later)
    }

    @Test func assignChangesOnlyThatApp() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        _ = layout.recordSighting(b, name: "B", at: t0)
        layout.assign(a, to: .alwaysHidden)
        #expect(layout.section(of: a) == .alwaysHidden)
        #expect(layout.section(of: b) == .visible)
    }

    @Test func forgetRemovesOnlyThatApp() {
        var layout = Layout()
        _ = layout.recordSighting(a, name: "A", at: t0)
        _ = layout.recordSighting(b, name: "B", at: t0)
        layout.forget(a)
        #expect(layout.section(of: a) == nil)
        #expect(layout.section(of: b) == .visible)
    }

    @Test func effectiveSectionFallsBackToDefault() {
        var layout = Layout()
        layout.defaultSection = .hidden
        #expect(layout.effectiveSection(of: a) == .hidden)
    }

    // Catches an Apple owner taking the default section, or MenuBarAgent and Control Center counting as assigned.
    @Test func anAppleOwnerIsAssignedOnlyWhenItIsAssignableAndAssigned() {
        var layout = Layout()
        layout.defaultSection = .hidden
        for owner in AppleOwners.all { #expect(layout.effectiveSection(of: owner) == .visible) }

        for owner in AppleOwners.all {
            _ = layout.recordSighting(owner, name: owner.bundleID, at: t0)
            layout.assign(owner, to: .alwaysHidden)
        }

        for owner in AppleOwners.all.subtracting(AppleOwners.assignable) {
            #expect(layout.assignedSection(of: .app(owner)) == nil)
        }
        for owner in AppleOwners.assignable { #expect(layout.assignedSection(of: .app(owner)) == .alwaysHidden) }
    }

    @Test func assigningASystemItemStoresItsSectionApartFromApps() {
        var layout = Layout()
        let wifi = SystemItemID(moduleName: "WiFi")
        #expect(layout.section(of: wifi) == nil)

        layout.assign(wifi, to: .hidden)

        #expect(layout.section(of: wifi) == .hidden)
        #expect(layout.systemItems == [wifi: .hidden])
        #expect(layout.apps.isEmpty)
    }

    @Test func aSystemItemUnitIsTheModuleEvenWhenItsOwnerIsAnApp() {
        let wifi = SystemItemID(moduleName: "WiFi")
        let item = MenuBarItem(
            key: ItemKey(raw: "module:WiFi"), owner: .app(AppID("com.apple.controlcenter"), name: "Control Center"),
            isManagedByMacOS: true, systemItem: wifi)

        #expect(item.unit == .systemItem(wifi))
    }

    @Test func anAppItemsUnitIsItsApp() {
        let item = MenuBarItem(key: ItemKey(raw: "k"), owner: .app(a, name: "A"))

        #expect(item.unit == .app(a))
    }

    @Test func aManagedItemWithoutASystemItemHasNoUnit() {
        let item = MenuBarItem(
            key: ItemKey(raw: "module:Sound"), owner: .app(AppID("com.apple.controlcenter"), name: "Control Center"),
            isManagedByMacOS: true)

        #expect(item.unit == nil)
    }

    @Test func anUnresolvedOwnerHasNoUnit() {
        let item = MenuBarItem(key: ItemKey(raw: "k"), owner: .unresolved(processName: "mystery"))

        #expect(item.unit == nil)
    }

    @Test func appleOwnersSplitIntoAssignableAndNeverOffTheAllowlist() {
        let assignable = ["com.apple.systemuiserver", "com.apple.TextInputMenuAgent"]
        let fixed = ["com.apple.MenuBarAgent", "com.apple.controlcenter"]
        #expect(AppleOwners.assignable == Set(assignable.map(AppID.init)))
        #expect(AppleOwners.all == Set((assignable + fixed).map(AppID.init)))

        for bundleID in assignable + fixed {
            #expect(MenuBarItem(key: ItemKey(raw: "k"), owner: .app(AppID(bundleID), name: "Apple")).isAppleItem)
        }
        #expect(!MenuBarItem(key: ItemKey(raw: "k"), owner: .app(a, name: "A")).isAppleItem)
        #expect(!MenuBarItem(key: ItemKey(raw: "k"), owner: .unresolved(processName: "mystery")).isAppleItem)
    }
}
