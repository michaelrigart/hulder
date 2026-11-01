import HulderCore

/// Names drawn items the way the order file does. A drawn item carries no name, so an owner's items take the
/// order file's entries for that owner from the right, and any left over get the next free `Item-<n>`.
enum ItemKeyBuilder {
    static func ownerToken(_ owner: ItemOwner) -> String {
        switch owner {
        case .app(let appID, _): appID.bundleID
        case .unresolved(let processName): processName
        }
    }

    /// One key per drawn item, left to right.
    static func keys(ownerToken: String, drawnCount: Int, entries: [String: Double]) -> [ItemKey] {
        guard drawnCount > 0 else { return [] }
        let prefix = "status:\(ownerToken)::"
        var candidates = entries.keys.filter { $0.hasPrefix(prefix) }
        if candidates.count > drawnCount {
            candidates = Array(candidates.sorted { isBefore(suffix: $0.dropFirst(prefix.count), suffix: $1.dropFirst(prefix.count)) }.prefix(drawnCount))
        }
        let placed = leftToRight(candidates, entries: entries)
        let used = Set(candidates.compactMap { itemIndex(of: $0.dropFirst(prefix.count)) })
        var next = 0
        // The smallest unused index goes to the rightmost left-over item, so the list is reversed to read left to right.
        let leftOver = (0..<(drawnCount - placed.count)).map { _ -> String in
            while used.contains(next) { next += 1 }
            defer { next += 1 }
            return "\(prefix)Item-\(next)"
        }
        return (leftOver.reversed() + placed).map(ItemKey.init(raw:))
    }

    /// MenuBarAgent's own items take the order file's `module:` entries from the right. Left-over items get
    /// placeholders; these items are read-only, so a wrong label costs nothing else.
    static func systemKeys(drawnCount: Int, entries: [String: Double]) -> [ItemKey] {
        guard drawnCount > 0 else { return [] }
        let modules = leftToRight(entries.keys.filter { $0.hasPrefix("module:") }, entries: entries)
        let taken = Array(modules.suffix(drawnCount))
        let placeholders = (0..<(drawnCount - taken.count)).map { "module:#\($0)" }
        return (placeholders + taken).map(ItemKey.init(raw:))
    }

    /// The order file's left-to-right order: descending value (larger sits further left), then ascending key.
    static func leftToRight(_ keys: some Sequence<String>, entries: [String: Double]) -> [String] {
        keys.sorted { lhs, rhs in
            let (left, right) = (entries[lhs] ?? 0, entries[rhs] ?? 0)
            return left != right ? left > right : lhs < rhs
        }
    }

    private static func itemIndex(of suffix: Substring) -> Int? {
        guard suffix.hasPrefix("Item-") else { return nil }
        let digits = suffix.dropFirst("Item-".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// `Item-<n>` by ascending n, then every other suffix alphabetically.
    private static func isBefore(suffix lhs: Substring, suffix rhs: Substring) -> Bool {
        switch (itemIndex(of: lhs), itemIndex(of: rhs)) {
        case (let left?, let right?): left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs < rhs
        }
    }
}
