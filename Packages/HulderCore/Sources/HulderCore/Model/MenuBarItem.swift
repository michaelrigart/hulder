public struct ItemKey: Hashable, Codable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

public enum ItemOwner: Hashable, Sendable {
    case app(AppID, name: String)
    case unresolved(processName: String)

    public var id: String {
        switch self {
        case .app(let appID, _): appID.bundleID
        case .unresolved(let processName): "process:" + processName
        }
    }

    public var appID: AppID? {
        switch self {
        case .app(let appID, _): appID
        case .unresolved: nil
        }
    }
}

public struct MenuBarItem: Hashable, Sendable {
    public var key: ItemKey
    public var owner: ItemOwner
    public var description: String?
    public var title: String?
    public var isManagedByMacOS: Bool
    /// The item's left edge on the bar, or nil when it isn't drawn.
    public var barPosition: Double?
    /// False when the order file can't tell this item's entry apart from another entry of its app, so the
    /// item's key may stand for the wrong one. Hulder doesn't move such an item.
    public var orderKeyIsCertain: Bool

    public init(
        key: ItemKey,
        owner: ItemOwner,
        description: String? = nil,
        title: String? = nil,
        isManagedByMacOS: Bool = false,
        barPosition: Double? = nil,
        orderKeyIsCertain: Bool = true
    ) {
        self.key = key
        self.owner = owner
        self.description = description
        self.title = title
        self.isManagedByMacOS = isManagedByMacOS
        self.barPosition = barPosition
        self.orderKeyIsCertain = orderKeyIsCertain
    }
}
