import HulderCore

/// Names drawn items the way the order file does. An app's drawn items carry no name, so an owner's items take the
/// order file's entries for that owner from the right, and any left over get the next free `Item-<n>`. MenuBarAgent's
/// own items are named by the identifier of the menu extra they host where they have one.
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

    /// The order-file entries for one owner.
    static func candidates(ownerToken: String, entries: [String: Double]) -> [String] {
        let prefix = "status:\(ownerToken)::"
        return entries.keys.filter { $0.hasPrefix(prefix) }
    }

    /// Where an item's own entry must lie: below `upper`, the value of the nearest certain item on its left, and
    /// above `lower`, the value of the nearest certain item on its right. A missing side is unbounded.
    struct Bounds: Equatable, Sendable {
        var upper: Double?
        var lower: Double?

        func contains(_ value: Double) -> Bool {
            (upper.map { value < $0 } ?? true) && (lower.map { value > $0 } ?? true)
        }
    }

    /// One key per drawn item, left to right, for an owner with more entries than drawn items. An item takes the
    /// one entry whose value lies inside its bounds and is certain. When none or several do, or when another item
    /// of the owner takes the same entry, it is uncertain and takes a key as `keys` would give it.
    static func bracketed(
        ownerToken: String, bounds: [Bounds], entries: [String: Double]
    ) -> [(key: ItemKey, isCertain: Bool)] {
        let candidates = candidates(ownerToken: ownerToken, entries: entries)
        var fitting: [Int: String] = [:]
        for (index, bound) in bounds.enumerated() {
            let fits = candidates.filter { bound.contains(entries[$0] ?? 0) }
            if fits.count == 1 { fitting[index] = fits[0] }
        }
        let takenBy = Dictionary(grouping: fitting.keys, by: { fitting[$0] })
        let certain = fitting.filter { takenBy[$0.value]?.count == 1 }
        let unresolved = bounds.indices.filter { certain[$0] == nil }
        var remaining = entries
        certain.values.forEach { remaining[$0] = nil }
        var guesses = keys(ownerToken: ownerToken, drawnCount: unresolved.count, entries: remaining).makeIterator()
        return bounds.indices.map { index in
            if let key = certain[index] { return (ItemKey(raw: key), true) }
            return (guesses.next() ?? ItemKey(raw: "status:\(ownerToken)::Item-\(index)"), false)
        }
    }

    /// Hulder's own items. Its status item is named, so the leftmost drawn item is exactly that item's key, never
    /// a guess among the order file's entries, which can still hold an older `Item-<n>` for the bundle identifier.
    /// Any further drawn item is named the usual way from the entries left over.
    static func ownKeys(ownerToken: String, autosaveName: String, drawnCount: Int, entries: [String: Double]) -> [ItemKey] {
        guard drawnCount > 0 else { return [] }
        let named = "status:\(ownerToken)::\(autosaveName)"
        var others = entries
        others[named] = nil
        return ([ItemKey(raw: named)] + keys(ownerToken: ownerToken, drawnCount: drawnCount - 1, entries: others))
    }

    /// The prefix of the identifier a menu extra that MenuBarAgent hosts carries, such as `com.apple.menuextra.wifi`.
    private static let menuExtraPrefix = "com.apple.menuextra."
    /// The identifier names that the order file calls something else, lowercased.
    private static let moduleAliases = ["controlcenter": "bentobox", "focusmode": "focusmodes"]

    /// MenuBarAgent's own items, left to right. An item whose identifier names a menu extra takes the `module:`
    /// entry of that name, each entry at most once: the exact name first, then the one free entry whose name and the
    /// identifier's begin alike. The others take the entries left over from the right; items beyond them get
    /// placeholders, and these items are read-only, so a wrong label costs nothing else.
    static func systemKeys(identifiers: [String?], entries: [String: Double]) -> [ItemKey] {
        guard !identifiers.isEmpty else { return [] }
        var free = leftToRight(entries.keys.filter { $0.hasPrefix("module:") }, entries: entries)
        var keys = [String?](repeating: nil, count: identifiers.count)
        for (index, identifier) in identifiers.enumerated() {
            guard let name = moduleName(forIdentifier: identifier), let match = freeEntry(named: name, in: free) else { continue }
            keys[index] = free.remove(at: match)
        }
        let unnamed = keys.indices.filter { keys[$0] == nil }
        let taken = Array(free.suffix(unnamed.count))
        let positional = (0..<(unnamed.count - taken.count)).map { "module:#\($0)" } + taken
        for (index, key) in zip(unnamed, positional) { keys[index] = key }
        return keys.compactMap { $0 }.map(ItemKey.init(raw:))
    }

    /// The index of the free entry for a lowercased module name: the entry of exactly that name, else the only entry
    /// whose name begins with it or that it begins with. Nil when none or several match.
    private static func freeEntry(named name: String, in free: [String]) -> Int? {
        guard !name.isEmpty else { return nil }
        let names = free.map { ItemKey(raw: $0).moduleName?.lowercased() ?? "" }
        if let exact = names.firstIndex(of: name) { return exact }
        let related = names.indices.filter { !names[$0].isEmpty && (names[$0].hasPrefix(name) || name.hasPrefix(names[$0])) }
        return related.count == 1 ? related[0] : nil
    }

    /// The lowercased module name a menu extra's identifier stands for, or nil when it isn't one.
    private static func moduleName(forIdentifier identifier: String?) -> String? {
        guard let identifier, identifier.hasPrefix(menuExtraPrefix) else { return nil }
        let name = identifier.dropFirst(menuExtraPrefix.count).lowercased()
        return moduleAliases[name] ?? name
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
