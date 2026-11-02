import Darwin
import HulderCore

/// Turns one read of the bar into per-owner scans. Pure: the Accessibility reads happen before it.
enum InventoryAssembly {
    static let macOSManagedBundleIDs: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.controlcenter",
    ]

    /// One owner's drawn items, left to right. `positions` are their places among all the groups the bar draws.
    private struct Drawn {
        var owner: ItemOwner
        var groups: [DrawnGroup] = []
        var positions: [Int] = []
        var keys: [ItemKey] = []
        /// Per item; empty when every key is certain.
        var certain: [Bool] = []
        /// Set when the owner has more entries than drawn items, which the keys alone can't settle.
        var ambiguousToken: String?
        /// Whether its keys are exact enough to bound another owner's: not MenuBarAgent's, whose `module:` keys
        /// are positional guesses.
        var isBound = true
    }

    /// `concealed` is the running apps the live concealment hides. Only they can be missing from the bar while
    /// they still have items; any other running app without an icon has none to show. A concealed app without
    /// order entries times out, keeping its last known items.
    /// `own` is Hulder: its one status item has the key the platform named it with, and an app that draws nothing
    /// has no items, whatever the order file holds for its bundle identifier.
    static func scans(
        snapshot: BarSnapshot?,
        owners: [pid_t: ItemOwner],
        listings: [pid_t: [RawItem]],
        entries: [String: Double]?,
        concealed: Set<AppID>,
        own: AppID? = nil,
        previousOwners: [ItemOwner]
    ) -> [AppScan] {
        guard let snapshot else {
            var seen = Set<String>()
            return previousOwners.filter { seen.insert($0.id).inserted }.map { AppScan(owner: $0, result: .timedOut) }
        }
        let entries = entries ?? [:]

        var order: [String] = []
        var drawn: [String: Drawn] = [:]
        for (position, group) in snapshot.groups.enumerated() {
            guard let owner = owners[group.pid] else { continue }
            if drawn[owner.id] == nil { order.append(owner.id) }
            drawn[owner.id, default: Drawn(owner: owner)].groups.append(group)
            drawn[owner.id]?.positions.append(position)
        }

        for id in order {
            guard var entry = drawn[id] else { continue }
            let (owner, count) = (entry.owner, entry.groups.count)
            if owner.appID?.bundleID == MenuBarAgentReader.agentBundleID {
                entry.keys = ItemKeyBuilder.systemKeys(drawnCount: count, entries: entries)
                entry.isBound = false
            } else if let own, owner.appID == own {
                entry.keys = ItemKeyBuilder.ownKeys(
                    ownerToken: own.bundleID, autosaveName: HulderPlatform27.statusItemAutosaveName,
                    drawnCount: count, entries: entries)
            } else {
                let token = ItemKeyBuilder.ownerToken(owner)
                entry.keys = ItemKeyBuilder.keys(ownerToken: token, drawnCount: count, entries: entries)
                if ItemKeyBuilder.candidates(ownerToken: token, entries: entries).count > count {
                    entry.ambiguousToken = token
                }
            }
            drawn[id] = entry
        }

        // The value of each drawn item whose key is certain, by position on the bar. Items of an owner with
        // more entries than drawn items are not among them, even when the bracketing below resolves them, and
        // neither are MenuBarAgent's.
        var anchors = [Double?](repeating: nil, count: snapshot.groups.count)
        for entry in drawn.values where entry.ambiguousToken == nil && entry.isBound {
            for (position, key) in zip(entry.positions, entry.keys) { anchors[position] = entries[key.raw] }
        }
        for id in order {
            guard var entry = drawn[id], let token = entry.ambiguousToken else { continue }
            let bounds = entry.positions.map { position in
                ItemKeyBuilder.Bounds(
                    upper: anchors[..<position].last { $0 != nil } ?? nil,
                    lower: anchors[(position + 1)...].first { $0 != nil } ?? nil)
            }
            let resolved = ItemKeyBuilder.bracketed(ownerToken: token, bounds: bounds, entries: entries)
            entry.keys = resolved.map(\.key)
            entry.certain = resolved.map(\.isCertain)
            drawn[id] = entry
        }

        var scans: [AppScan] = []
        for id in order {
            guard let entry = drawn[id] else { continue }
            let (owner, groups) = (entry.owner, entry.groups)
            var described = describe(groups, listings: listings)
            let managed = owner.appID.map { macOSManagedBundleIDs.contains($0.bundleID) } ?? false
            let items = zip(groups.indices, groups).map { index, group -> MenuBarItem in
                let text = described[group.pid]?.removeFirst()
                return MenuBarItem(
                    key: entry.keys[index], owner: owner, description: text?.description, title: text?.title,
                    isManagedByMacOS: managed, barPosition: group.frame.minX,
                    orderKeyIsCertain: entry.certain.isEmpty || entry.certain[index]
                )
            }
            scans.append(AppScan(owner: owner, result: .complete(items)))
        }

        for appID in concealed.sorted() where drawn[appID.bundleID] == nil && appID != own {
            let prefix = "status:\(appID.bundleID)::"
            let own = ItemKeyBuilder.leftToRight(entries.keys.filter { $0.hasPrefix(prefix) }, entries: entries)
            let owner = owners.values.first { $0.appID == appID }
                ?? previousOwners.first { $0.appID == appID }
                ?? .app(appID, name: appID.bundleID)
            // Without entries nothing says what the app has, so its last known items stay, stale.
            guard !own.isEmpty else {
                scans.append(AppScan(owner: owner, result: .timedOut))
                continue
            }
            let managed = macOSManagedBundleIDs.contains(appID.bundleID)
            let items = own.map { MenuBarItem(key: ItemKey(raw: $0), owner: owner, isManagedByMacOS: managed) }
            scans.append(AppScan(owner: owner, result: .complete(items)))
        }
        return scans
    }

    /// The bundle identifiers of the apps that own items, from one pass. An owner whose scan did not complete
    /// still counts: its last known items are kept. One that completed with none, or that has no bundle
    /// identifier, does not.
    static func ownerIDs(of scans: [AppScan]) -> Set<String> {
        Set(scans.compactMap { scan -> String? in
            if case .complete(let items) = scan.result, items.isEmpty { return nil }
            return scan.owner.appID?.bundleID
        })
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
