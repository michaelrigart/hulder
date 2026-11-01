import Darwin
import HulderCore

/// Turns one read of the bar into per-owner scans. Pure: the Accessibility reads happen before it.
enum InventoryAssembly {
    static let macOSManagedBundleIDs: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.controlcenter",
    ]

    static func scans(
        snapshot: BarSnapshot?,
        owners: [pid_t: ItemOwner],
        listings: [pid_t: [RawItem]],
        entries: [String: Double]?,
        running: Set<AppID>,
        previousOwners: [ItemOwner]
    ) -> [AppScan] {
        guard let snapshot else {
            var seen = Set<String>()
            return previousOwners.filter { seen.insert($0.id).inserted }.map { AppScan(owner: $0, result: .timedOut) }
        }
        let entries = entries ?? [:]

        var order: [String] = []
        var drawn: [String: (owner: ItemOwner, groups: [DrawnGroup])] = [:]
        for group in snapshot.groups {
            guard let owner = owners[group.pid] else { continue }
            if drawn[owner.id] == nil { order.append(owner.id) }
            drawn[owner.id, default: (owner, [])].groups.append(group)
        }

        var scans: [AppScan] = []
        for id in order {
            guard let entry = drawn[id] else { continue }
            let (owner, groups) = (entry.owner, entry.groups)
            let keys = owner.appID?.bundleID == MenuBarAgentReader.agentBundleID
                ? ItemKeyBuilder.systemKeys(drawnCount: groups.count, entries: entries)
                : ItemKeyBuilder.keys(ownerToken: ItemKeyBuilder.ownerToken(owner), drawnCount: groups.count, entries: entries)
            var described = describe(groups, listings: listings)
            let managed = owner.appID.map { macOSManagedBundleIDs.contains($0.bundleID) } ?? false
            let items = zip(groups, keys).map { group, key -> MenuBarItem in
                let text = described[group.pid]?.removeFirst()
                return MenuBarItem(
                    key: key, owner: owner, description: text?.description, title: text?.title,
                    isManagedByMacOS: managed, barPosition: group.frame.minX
                )
            }
            scans.append(AppScan(owner: owner, result: .complete(items)))
        }

        for appID in running.sorted() where drawn[appID.bundleID] == nil {
            let prefix = "status:\(appID.bundleID)::"
            let own = ItemKeyBuilder.leftToRight(entries.keys.filter { $0.hasPrefix(prefix) }, entries: entries)
            guard !own.isEmpty else { continue }
            let owner = owners.values.first { $0.appID == appID }
                ?? previousOwners.first { $0.appID == appID }
                ?? .app(appID, name: appID.bundleID)
            let managed = macOSManagedBundleIDs.contains(appID.bundleID)
            let items = own.map { MenuBarItem(key: ItemKey(raw: $0), owner: owner, isManagedByMacOS: managed) }
            scans.append(AppScan(owner: owner, result: .complete(items)))
        }
        return scans
    }

    /// The leftmost item of Hulder's own, or nil when none is drawn or listed.
    static func ownItemKey(in snapshot: InventorySnapshot, ownAppID: AppID) -> ItemKey? {
        snapshot.items.enumerated()
            .filter { $0.element.owner.appID == ownAppID }
            .min { ($0.element.barPosition ?? .infinity, $0.offset) < ($1.element.barPosition ?? .infinity, $1.offset) }?
            .element.key
    }

    /// Each process's descriptions and titles, left to right, when its listing has exactly as many items as the
    /// bar draws for it.
    private static func describe(_ groups: [DrawnGroup], listings: [pid_t: [RawItem]]) -> [pid_t: [(description: String?, title: String?)]] {
        var drawnCounts: [pid_t: Int] = [:]
        for group in groups { drawnCounts[group.pid, default: 0] += 1 }
        var result: [pid_t: [(description: String?, title: String?)]] = [:]
        for (pid, count) in drawnCounts {
            guard let listing = listings[pid], listing.count == count else { continue }
            let ordered = listing.allSatisfy { $0.frame != nil }
                ? listing.sorted { ($0.frame?.minX ?? 0, $0.index) < ($1.frame?.minX ?? 0, $1.index) }
                : listing.sorted { $0.index < $1.index }
            result[pid] = ordered.map { ($0.description, $0.title) }
        }
        return result
    }
}
