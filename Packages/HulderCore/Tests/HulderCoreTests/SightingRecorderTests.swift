import Foundation
import Testing
@testable import HulderCore

struct SightingRecorderTests {
    private let own = AppID("com.michaelrigart.hulder")

    private func item(
        _ name: String,
        at position: Double? = nil,
        managedByMacOS: Bool = false
    ) -> MenuBarItem {
        MenuBarItem(
            key: ItemKey(raw: "\(name)-\(position ?? -1)"),
            owner: .app(AppID("com.example.\(name)"), name: name.uppercased()),
            isManagedByMacOS: managedByMacOS,
            barPosition: position
        )
    }

    private func names(_ snapshot: InventorySnapshot) -> [String] {
        SightingRecorder.sightings(in: snapshot, own: own, known: []).map(\.0.bundleID)
    }

    @Test func sightingsIncludeKnownAppsAndSkipMacOSAndStale() {
        let snapshot = InventorySnapshot(
            items: [
                item("known", at: 10),
                item("clock", at: 20, managedByMacOS: true),
                item("stale", at: 30),
                item("fresh", at: 40),
                MenuBarItem(key: ItemKey(raw: "u"), owner: .unresolved(processName: "helper"), barPosition: 5),
            ],
            stale: ["com.example.stale"]
        )

        let sightings = SightingRecorder.sightings(in: snapshot, own: own, known: [AppID("com.example.stale")])

        #expect(sightings.map(\.0) == [AppID("com.example.known"), AppID("com.example.fresh")])
        #expect(sightings.map(\.1) == ["KNOWN", "FRESH"])
    }

    // Review of this task, finding 1: catches a hidden new app excluded forever. Every hidden app Hulder has seen
    // drawn is stale, and a stale app is skipped only to keep a known app's name and day from changing.
    @Test func aStaleAppTheLayoutDoesNotKnowIsStillASighting() {
        let snapshot = InventorySnapshot(items: [item("x", at: 10)], stale: ["com.example.x"])
        let app = AppID("com.example.x")

        #expect(SightingRecorder.sightings(in: snapshot, own: own, known: []).map(\.0) == [app])
        #expect(SightingRecorder.sightings(in: snapshot, own: own, known: [app]).isEmpty)
    }

    @Test func sightingsFollowBarPosition() {
        let snapshot = InventorySnapshot(
            items: [item("a", at: 300), item("b", at: 100), item("c")],
            stale: []
        )

        #expect(names(snapshot) == ["com.example.b", "com.example.a", "com.example.c"])
    }

    @Test func undrawnAppsComeLastByBundleIdentifier() {
        let snapshot = InventorySnapshot(items: [item("z"), item("m", at: 50), item("d")], stale: [])

        #expect(names(snapshot) == ["com.example.m", "com.example.d", "com.example.z"])
    }

    @Test func anAppSitsAtItsLeftmostDrawnItem() {
        let snapshot = InventorySnapshot(
            items: [item("a"), item("a", at: 300), item("b", at: 100), item("c")],
            stale: []
        )

        #expect(names(snapshot) == ["com.example.b", "com.example.a", "com.example.c"])
    }

    @Test func aDrawnItemAfterAnUndrawnOneStillPlacesTheApp() {
        let snapshot = InventorySnapshot(
            items: [item("z"), item("z", at: 300), item("m"), item("d", at: 100)],
            stale: []
        )

        #expect(names(snapshot) == ["com.example.d", "com.example.z", "com.example.m"])
    }

    @Test func anAppSitsAtTheMinimumOfItsDrawnPositions() {
        let snapshot = InventorySnapshot(items: [item("a", at: 300), item("a", at: 50), item("b", at: 100)], stale: [])

        #expect(names(snapshot) == ["com.example.a", "com.example.b"])
    }

    @Test func anAppWithSeveralItemsAppearsOnce() {
        let snapshot = InventorySnapshot(items: [item("a", at: 10), item("a", at: 90), item("b", at: 50)], stale: [])

        #expect(names(snapshot) == ["com.example.a", "com.example.b"])
    }

    @Test func ownAppIsNeverASighting() {
        let ownItem = MenuBarItem(key: ItemKey(raw: "own"), owner: .app(own, name: "Hulder"), barPosition: 1)
        let snapshot = InventorySnapshot(items: [ownItem, item("a", at: 2)], stale: [])

        #expect(names(snapshot) == ["com.example.a"])
    }

    @Test func applesOwnersAreNeverSightings() {
        let snapshot = InventorySnapshot(
            items: [
                MenuBarItem(
                    key: ItemKey(raw: "siri"), owner: .app(AppID("com.apple.systemuiserver"), name: "SystemUIServer"),
                    barPosition: 10),
                MenuBarItem(
                    key: ItemKey(raw: "input"),
                    owner: .app(AppID("com.apple.TextInputMenuAgent"), name: "TextInputMenuAgent"), barPosition: 20),
                item("app", at: 30),
            ],
            stale: [])

        #expect(names(snapshot) == ["com.example.app"])
    }
}

struct SightingAllowlistTests {
    @Test func sightingDoesNotChangeTheAllowlist() {
        let own = AppID("com.michaelrigart.hulder")
        let known = AppID("com.example.known")
        let unknown = AppID("com.example.unknown")

        for section in Section.allCases {
            var layout = Layout()
            _ = layout.recordSighting(known, name: "known", at: Date(timeIntervalSince1970: 0))
            layout.assign(known, to: .visible)
            layout.defaultSection = section

            let before = ConcealmentPlanner.plan(layout: layout, state: .hidden, running: [known, unknown], own: own)
            _ = layout.recordSighting(unknown, name: "unknown", at: Date(timeIntervalSince1970: 1))
            let after = ConcealmentPlanner.plan(layout: layout, state: .hidden, running: [known, unknown], own: own)

            #expect(before == after, "default section \(section)")
        }
    }
}
