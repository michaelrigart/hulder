public enum InventoryMerger {
    public static func merge(previous: InventorySnapshot, scans: [AppScan]) -> InventorySnapshot {
        var items: [MenuBarItem] = []
        var stale: Set<String> = []
        for scan in scans {
            switch scan.result {
            case .complete(let scanned):
                items += scanned
            case .timedOut, .failed:
                items += previous.items.filter { $0.owner.id == scan.owner.id }
                stale.insert(scan.owner.id)
            }
        }
        return InventorySnapshot(items: items, stale: stale)
    }
}
