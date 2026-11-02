import Foundation

public struct ItemKey: Hashable, Codable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    private static let moduleNames = [
        "WiFi": "Wi-Fi", "BentoBox": "Control Center", "FocusModes": "Focus", "NowPlaying": "Now Playing",
        "ScreenMirroring": "Screen Mirroring", "AudioVideoModule": "Audio and Video",
    ]

    /// Apple's name for a status item whose key gives only `Item-<n>`: the Input Menu of System Settings › Keyboard.
    private static let inputMenuBundle = "status:com.apple.TextInputMenuAgent::"

    /// Whether macOS draws the item itself (a `module:` key) rather than an app.
    public var isModule: Bool { raw.hasPrefix("module:") }

    /// A readable name read from the key, for an item that has no description or title. MenuBarAgent's items give
    /// none, so `module:WiFi` is "Wi-Fi". A status key gives its autosave name unless that is `Item-<n>` or a UUID;
    /// TextInputMenuAgent's `Item-<n>` is "Input Menu".
    public var derivedName: String? {
        if isModule {
            var module = String(raw.dropFirst("module:".count))
            if let dash = module.lastIndex(of: "-"), module[module.index(after: dash)...].allSatisfy(\.isASCIIDigit),
               module.index(after: dash) != module.endIndex {
                module = String(module[..<dash])
            }
            guard !module.isEmpty else { return nil }
            return Self.moduleNames[module] ?? Self.splitWords(module)
        }
        guard raw.hasPrefix("status:"), let separator = raw.range(of: "::") else { return nil }
        let name = String(raw[separator.upperBound...])
        let isItemNumber = name.hasPrefix("Item-") && !name.dropFirst("Item-".count).isEmpty
            && name.dropFirst("Item-".count).allSatisfy(\.isASCIIDigit)
        if isItemNumber, raw.hasPrefix(Self.inputMenuBundle) { return "Input Menu" }
        guard !name.isEmpty, !isItemNumber, UUID(uuidString: name) == nil else { return nil }
        return name
    }

    /// "UserSwitcher" as "User Switcher": a space before each capital that follows a lowercase letter or a digit.
    private static func splitWords(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isASCIIDigit { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
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
