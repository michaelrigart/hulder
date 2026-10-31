public struct BarOrder: Equatable, Sendable {
    /// Item keys, left to right.
    public var keys: [ItemKey]
    public var pinned: Set<ItemKey>

    public init(keys: [ItemKey], pinned: Set<ItemKey>) {
        self.keys = keys
        self.pinned = pinned
    }
}

public struct OrderChange: Equatable, Sendable {
    public var target: [ItemKey]
    /// The relocated keys, in target order.
    public var moved: [ItemKey]

    public init(target: [ItemKey], moved: [ItemKey]) {
        self.target = target
        self.moved = moved
    }
}

public struct OrderContext: Sendable {
    public let order: BarOrder
    public let divider: ItemKey?
    private let itemsByKey: [ItemKey: MenuBarItem]
    private let layout: Layout

    public init(order: BarOrder, divider: ItemKey?, items: [MenuBarItem], layout: Layout) {
        self.order = order
        self.divider = divider
        self.itemsByKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.layout = layout
    }

    /// Nil for items managed by macOS, unresolved owners and unknown keys.
    public func section(of key: ItemKey) -> Section? {
        guard let item = itemsByKey[key], !item.isManagedByMacOS, let app = item.owner.appID else {
            return nil
        }
        return layout.effectiveSection(of: app)
    }
}

public enum OrderPlanner {
    public static func placeAtDivider(
        _ keys: [ItemKey], section: Section, in context: OrderContext
    ) -> OrderChange? {
        move(keys, in: context) { remaining, divider in
            switch section {
            case .visible: divider + 1
            case .hidden: divider
            case .alwaysHidden: alwaysHiddenBoundary(in: remaining, divider: divider, context: context)
            }
        }
    }

    public static func drop(
        _ keys: [ItemKey], section: Section, before anchor: ItemKey?, in context: OrderContext
    ) -> OrderChange? {
        move(keys, in: context) { remaining, divider in
            let firstPinned = firstPinnedIndex(in: remaining, after: divider, context: context)
            if let anchor {
                guard let index = remaining.firstIndex(of: anchor) else { return nil }
                return min(index, firstPinned ?? remaining.count)
            }
            switch section {
            case .alwaysHidden: return alwaysHiddenBoundary(in: remaining, divider: divider, context: context)
            case .hidden: return divider
            case .visible: return firstPinned ?? remaining.count
            }
        }
    }

    public static func misplaced(in context: OrderContext) -> [ItemKey] {
        guard let divider = dividerIndex(in: context.order.keys, context: context) else { return [] }
        let keys = context.order.keys
        let firstPinned = firstPinnedIndex(in: keys, after: divider, context: context) ?? keys.count
        return keys.enumerated().compactMap { index, key in
            guard let section = context.section(of: key) else { return nil }
            if index < divider { return section == .visible ? key : nil }
            if index > divider, index < firstPinned { return section == .visible ? nil : key }
            return nil
        }
    }

    public static func tidy(in context: OrderContext) -> OrderChange? {
        let misplaced = misplaced(in: context)
        guard !misplaced.isEmpty else { return nil }
        let moving = Set(misplaced)
        var target = context.order.keys.filter { !moving.contains($0) }
        for section in [Section.visible, .hidden, .alwaysHidden] {
            let block = misplaced.filter { context.section(of: $0) == section }
            guard !block.isEmpty, let divider = dividerIndex(in: target, context: context) else { continue }
            let index = switch section {
            case .visible: divider + 1
            case .hidden: divider
            case .alwaysHidden: alwaysHiddenBoundary(in: target, divider: divider, context: context)
            }
            target.insert(contentsOf: block, at: index)
        }
        return change(from: context.order.keys, to: target, moving: moving)
    }

    private static func move(
        _ keys: [ItemKey],
        in context: OrderContext,
        insertionIndex: (_ remaining: [ItemKey], _ divider: Int) -> Int?
    ) -> OrderChange? {
        guard dividerIndex(in: context.order.keys, context: context) != nil else { return nil }
        let wanted = Set(keys)
        let moving = Set(context.order.keys.filter {
            wanted.contains($0) && $0 != context.divider && !context.order.pinned.contains($0)
                && context.section(of: $0) != nil
        })
        guard !moving.isEmpty else { return nil }
        var target = context.order.keys.filter { !moving.contains($0) }
        guard let divider = dividerIndex(in: target, context: context),
              let index = insertionIndex(target, divider)
        else { return nil }
        target.insert(contentsOf: context.order.keys.filter(moving.contains), at: index)
        return change(from: context.order.keys, to: target, moving: moving)
    }

    private static func change(from current: [ItemKey], to target: [ItemKey], moving: Set<ItemKey>) -> OrderChange? {
        guard target != current else { return nil }
        return OrderChange(target: target, moved: target.filter(moving.contains))
    }

    private static func dividerIndex(in keys: [ItemKey], context: OrderContext) -> Int? {
        context.divider.flatMap { keys.firstIndex(of: $0) }
    }

    /// Before the first Hidden key left of the divider, else right before the divider.
    private static func alwaysHiddenBoundary(in keys: [ItemKey], divider: Int, context: OrderContext) -> Int {
        keys[..<divider].firstIndex { context.section(of: $0) == .hidden } ?? divider
    }

    private static func firstPinnedIndex(in keys: [ItemKey], after divider: Int, context: OrderContext) -> Int? {
        keys.indices.first { $0 > divider && context.order.pinned.contains(keys[$0]) }
    }
}
