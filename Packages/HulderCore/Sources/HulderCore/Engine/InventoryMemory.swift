/// Builds the inventory from what each pass found and what earlier passes saw drawn.
///
/// The platform reports only evidence. This remembers, for the whole run, the items each owner was last seen
/// drawing, so an app that is hidden, or that quit and came back hidden, still shows what it last drew.
public struct InventoryMemory: Equatable, Sendable {
    private struct Remembered: Equatable, Sendable {
        var items: [MenuBarItem]
        /// Whether the pass that drew them read the order file. That says the file was read, not that each key
        /// matched an entry: an item drawn before macOS wrote its entry keeps an `Item-<n>` key made with the file.
        var keyedFromOrderFile: Bool
    }

    private var remembered: [String: Remembered] = [:]
    private var snapshot = InventorySnapshot.empty

    public init() {}

    public mutating func apply(_ pass: ScanPass) -> InventorySnapshot {
        guard let drawn = pass.drawn else {
            snapshot.stale.formUnion(snapshot.items.map(\.owner.id))
            return snapshot
        }
        var items: [MenuBarItem] = []
        var stale: Set<String> = []
        var drawnIDs: Set<String> = []
        for entry in drawn {
            drawnIDs.insert(entry.owner.id)
            remembered[entry.owner.id] = Remembered(items: entry.items, keyedFromOrderFile: pass.orderEntriesAvailable)
            items += entry.items
        }
        for entry in pass.concealed where drawnIDs.insert(entry.owner.id).inserted {
            let id = entry.owner.id
            let kept = remembered[id].map { memory in
                (items: memory.items.map { item -> MenuBarItem in
                    var item = item
                    item.barPosition = nil
                    return item
                }, fromOrderFile: memory.keyedFromOrderFile)
            }
            if let kept, kept.fromOrderFile {
                items += kept.items
                stale.insert(id)
            } else if !entry.items.isEmpty {
                items += entry.items
            } else {
                items += kept?.items ?? []
                stale.insert(id)
            }
        }
        snapshot = InventorySnapshot(items: items, stale: stale)
        return snapshot
    }
}
