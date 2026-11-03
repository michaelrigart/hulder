import Darwin
import HulderCore

/// Turns one read of the bar into a `ScanPass`. Pure: the Accessibility reads happen before it.
enum InventoryAssembly {
    static let macOSManagedBundleIDs: Set<String> = [
        MenuBarAgentReader.agentBundleID, "com.apple.controlcenter",
    ]

    /// One owner's drawn items, left to right. `positions` are their places among all the groups the bar draws.
    private struct Drawn {
        var owner: ItemOwner
        var groups: [DrawnGroup] = []
        var positions: [Int] = []
        var keys: [ItemKey] = []
        /// Per item; empty when every key is certain.
        var certain: [Bool] = []
        /// Per item; empty for an owner that hosts no modules.
        var systemItems: [SystemItemID?] = []
        /// Set when the owner has more entries than drawn items, which the keys alone can't settle.
        var ambiguousToken: String?
        /// Whether its keys are exact enough to bound another owner's: not MenuBarAgent's, whose `module:` keys
        /// are positional guesses for any item that hosts no named menu extra.
        var isBound = true
    }

    /// `concealed` is the running apps the live concealment hides. Only they can be missing from the bar while
    /// they still have items; any other running app without an icon has none to show. Each one the bar doesn't draw is
    /// reported, with the items its order entries give it, which may be none: what to keep of an app seen earlier is
    /// `InventoryMemory`'s decision. When it has more than one entry they are uncertain.
    /// `concealedSystemItems` is the modules the live concealment hides. MenuBarAgent no longer draws them, so each
    /// one the bar doesn't draw is reported among its items, without a position.
    /// `own` is Hulder: its one status item has the key the platform named it with, and an app that draws nothing
    /// has no items, whatever the order file holds for its bundle identifier.
    static func pass(
        snapshot: BarSnapshot?,
        owners: [pid_t: ItemOwner],
        listings: [pid_t: [RawItem]],
        entries: [String: Double]?,
        concealed: Set<AppID>,
        concealedSystemItems: Set<SystemItemID> = [],
        own: AppID? = nil
    ) -> ScanPass {
        guard let snapshot else { return .unread }
        let orderEntriesAvailable = entries != nil
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
                let resolved = ItemKeyBuilder.systemKeys(
                    identifiers: entry.groups.map(\.identifier), entries: entries, hidden: concealedSystemItems)
                entry.keys = resolved.map(\.key)
                entry.certain = resolved.map(\.isCertain)
                entry.systemItems = resolved.map(\.systemItem)
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

        var drawnOwners: [OwnerItems] = []
        for id in order {
            guard let entry = drawn[id] else { continue }
            let (owner, groups) = (entry.owner, entry.groups)
            var described = describe(groups, listings: listings)
            let managed = owner.appID.map { macOSManagedBundleIDs.contains($0.bundleID) } ?? false
            let isAgent = owner.appID?.bundleID == MenuBarAgentReader.agentBundleID
            var items = zip(groups.indices, groups).map { index, group -> MenuBarItem in
                let text = described[group.pid]?.removeFirst()
                return MenuBarItem(
                    key: entry.keys[index], owner: owner, description: text?.description, title: text?.title,
                    isManagedByMacOS: managed, barPosition: group.frame.minX,
                    orderKeyIsCertain: entry.certain.isEmpty || entry.certain[index],
                    systemItem: entry.systemItems.isEmpty ? nil : entry.systemItems[index]
                )
            }
            if isAgent {
                items += hiddenModules(
                    concealedSystemItems.subtracting(items.compactMap(\.systemItem)), owner: owner, entries: entries,
                    taken: Set(items.map(\.key.raw)))
            }
            drawnOwners.append(OwnerItems(owner: owner, items: items))
        }

        var concealedOwners: [OwnerItems] = []
        for appID in concealed.sorted() where drawn[appID.bundleID] == nil && appID != own {
            let owner = owners.values.first { $0.appID == appID } ?? .app(appID, name: appID.bundleID)
            let prefix = "status:\(appID.bundleID)::"
            let keys = ItemKeyBuilder.leftToRight(entries.keys.filter { $0.hasPrefix(prefix) }, entries: entries)
            // The entries are all there is to say what the app has. Several of them can't be told apart.
            let managed = macOSManagedBundleIDs.contains(appID.bundleID)
            let items = keys.map {
                MenuBarItem(
                    key: ItemKey(raw: $0), owner: owner, isManagedByMacOS: managed, orderKeyIsCertain: keys.count == 1)
            }
            concealedOwners.append(OwnerItems(owner: owner, items: items))
        }
        if !drawnOwners.contains(where: { $0.owner.appID?.bundleID == MenuBarAgentReader.agentBundleID }) {
            let owner = owners.values.first { $0.appID?.bundleID == MenuBarAgentReader.agentBundleID }
                ?? .app(AppID(MenuBarAgentReader.agentBundleID), name: "MenuBarAgent")
            let items = hiddenModules(concealedSystemItems, owner: owner, entries: entries, taken: [])
            if !items.isEmpty { concealedOwners.append(OwnerItems(owner: owner, items: items)) }
        }
        return ScanPass(drawn: drawnOwners, concealed: concealedOwners, orderEntriesAvailable: orderEntriesAvailable)
    }

    /// The modules the concealment hides, as MenuBarAgent's items without a bar position. A module takes its own
    /// `module:` entry from the order file, certain only when it has exactly one that no drawn item has taken;
    /// without one it is named `module:<order name>` and is uncertain. A module the table doesn't know is not reported.
    private static func hiddenModules(
        _ hidden: Set<SystemItemID>, owner: ItemOwner, entries: [String: Double], taken: Set<String>
    ) -> [MenuBarItem] {
        hidden.sorted().compactMap { id -> MenuBarItem? in
            guard SystemItemTable27.number(for: id) != nil else { return nil }
            let own = ItemKeyBuilder.leftToRight(
                entries.keys.filter { !taken.contains($0) && ItemKey(raw: $0).moduleName == id.moduleName }, entries: entries)
            return MenuBarItem(
                key: ItemKey(raw: own.first ?? "module:\(id.moduleName)"), owner: owner, isManagedByMacOS: true,
                orderKeyIsCertain: own.count == 1, systemItem: id)
        }
    }

    /// The processes that draw an item, or nil when the bar could not be read. Every process counts, whether or not
    /// anything names its owner: a process without a bundle identifier draws items too.
    static func drawnProcesses(of snapshot: BarSnapshot?) -> Set<pid_t>? {
        snapshot.map { Set($0.groups.map(\.pid)) }
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
