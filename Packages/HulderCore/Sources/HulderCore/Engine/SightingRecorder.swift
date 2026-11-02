public enum SightingRecorder {
    /// Every app that owns items, other than the platform's own app, macOS-managed items and stale apps that
    /// `known` holds: a known app's name and `lastSeen` change only from items seen now. An app the layout doesn't
    /// know stays a sighting while its items are stale, as every hidden app Hulder has seen drawn is.
    /// Ordered by the leftmost drawn item of each app; apps with no drawn item come last, by bundle
    /// identifier.
    public static func sightings(in snapshot: InventorySnapshot, own: AppID, known: Set<AppID>) -> [(AppID, String)] {
        var names: [AppID: String] = [:]
        var leftmost: [AppID: Double] = [:]
        for item in snapshot.items where !item.isManagedByMacOS {
            guard case .app(let app, let name) = item.owner, app != own else { continue }
            guard !snapshot.stale.contains(item.owner.id) || !known.contains(app) else { continue }
            names[app] = names[app] ?? name
            if let position = item.barPosition {
                leftmost[app] = min(leftmost[app] ?? position, position)
            }
        }
        return names.keys
            .sorted { lhs, rhs in
                switch (leftmost[lhs], leftmost[rhs]) {
                case (let left?, let right?): left == right ? lhs < rhs : left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs < rhs
                }
            }
            .map { ($0, names[$0] ?? $0.bundleID) }
    }
}
