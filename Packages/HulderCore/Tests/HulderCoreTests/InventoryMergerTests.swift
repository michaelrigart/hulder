import Testing
@testable import HulderCore

struct InventoryMergerTests {
    private func owner(_ name: String) -> ItemOwner {
        .app(AppID("com.example.\(name)"), name: name)
    }

    private func item(_ key: String, _ name: String) -> MenuBarItem {
        MenuBarItem(key: ItemKey(raw: key), owner: owner(name))
    }

    private var previous: InventorySnapshot {
        InventorySnapshot(
            items: [item("k1", "a"), item("k2", "a"), item("k3", "b")],
            stale: []
        )
    }

    @Test func timeoutKeepsLastKnownItemsAndMarksStale() {
        let before = InventorySnapshot(items: [item("k1", "a"), item("k2", "a")], stale: [])

        let merged = InventoryMerger.merge(previous: before, scans: [AppScan(owner: owner("a"), result: .timedOut)])

        #expect(merged.items == [item("k1", "a"), item("k2", "a")])
        #expect(merged.stale == ["com.example.a"])
    }

    @Test func completeReplacesAndClearsStale() {
        let before = InventorySnapshot(items: [item("k1", "a"), item("k2", "a")], stale: ["com.example.a"])

        let merged = InventoryMerger.merge(
            previous: before,
            scans: [AppScan(owner: owner("a"), result: .complete([item("k9", "a")]))]
        )

        #expect(merged.items == [item("k9", "a")])
        #expect(merged.stale.isEmpty)
    }

    @Test func allScansFailedKeepsEverythingStale() {
        let merged = InventoryMerger.merge(previous: previous, scans: [
            AppScan(owner: owner("a"), result: .failed),
            AppScan(owner: owner("b"), result: .timedOut),
        ])

        #expect(merged.items == previous.items)
        #expect(merged.stale == ["com.example.a", "com.example.b"])
    }

    @Test func absentOwnerIsDropped() {
        let merged = InventoryMerger.merge(
            previous: previous,
            scans: [AppScan(owner: owner("b"), result: .complete([item("k3", "b")]))]
        )

        #expect(merged.items == [item("k3", "b")])
        #expect(merged.stale.isEmpty)
    }

    @Test func itemsKeepTheirBarPosition() {
        let drawn = MenuBarItem(key: ItemKey(raw: "k1"), owner: owner("a"), barPosition: 120)

        let merged = InventoryMerger.merge(
            previous: .empty,
            scans: [AppScan(owner: owner("a"), result: .complete([drawn]))]
        )

        #expect(merged.items.first?.barPosition == 120)
    }
}
