import Foundation

public struct ItemKey: Hashable, Codable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    /// Each known module's readable name, where `splitWords` wouldn't give it, and its SF Symbol.
    private static let modules: [String: (name: String?, symbol: String)] = [
        "WiFi": ("Wi-Fi", "wifi"), "Battery": (nil, "battery.100percent"), "Clock": (nil, "clock"),
        "BentoBox": ("Control Center", "switch.2"), "FocusModes": ("Focus", "moon.fill"),
        "NowPlaying": ("Now Playing", "play.fill"), "ScreenMirroring": ("Screen Mirroring", "rectangle.on.rectangle"),
        "Sound": (nil, "speaker.wave.2.fill"), "Display": (nil, "sun.max"),
        "AudioVideoModule": ("Audio and Video", "video.fill"),
    ]

    /// Apple's name for a status item whose key gives only `Item-<n>`: the Input Menu of System Settings › Keyboard.
    private static let inputMenuBundle = "status:com.apple.TextInputMenuAgent::"

    /// Whether macOS draws the item itself (a `module:` key) rather than an app.
    public var isModule: Bool { raw.hasPrefix("module:") }

    /// A module key's name without `module:` and without a trailing `-<digits>`, as in `BentoBox` for
    /// `module:BentoBox-0`. Nil for any other key.
    public var moduleName: String? {
        guard isModule else { return nil }
        var module = raw.dropFirst("module:".count)
        if let dash = module.lastIndex(of: "-") {
            let digits = module[module.index(after: dash)...]
            if !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) { module = module[..<dash] }
        }
        return String(module)
    }

    /// The SF Symbol of a known module, else nil.
    public var moduleSymbol: String? {
        moduleName.flatMap { Self.modules[$0]?.symbol }
    }

    /// A readable name read from the key, for an item that has no description or title. MenuBarAgent's items give
    /// none, so `module:WiFi` is "Wi-Fi". A status key gives its autosave name unless that is `Item-<n>` or a UUID;
    /// TextInputMenuAgent's `Item-<n>` is "Input Menu".
    public var derivedName: String? {
        if isModule {
            guard let module = moduleName, !module.isEmpty else { return nil }
            return Self.modules[module]?.name ?? Self.splitWords(module)
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
    /// The system item this module stands for, when Hulder can hide it.
    public var systemItem: SystemItemID?

    /// What a section can be assigned to: the system item, else the app that owns an item macOS doesn't manage.
    public var unit: AssignableUnit? {
        if let systemItem { return .systemItem(systemItem) }
        guard !isManagedByMacOS, let appID = owner.appID else { return nil }
        return .app(appID)
    }

    public var isAppleItem: Bool {
        owner.appID.map(AppleOwners.all.contains) ?? false
    }

    public init(
        key: ItemKey,
        owner: ItemOwner,
        description: String? = nil,
        title: String? = nil,
        isManagedByMacOS: Bool = false,
        barPosition: Double? = nil,
        orderKeyIsCertain: Bool = true,
        systemItem: SystemItemID? = nil
    ) {
        self.key = key
        self.owner = owner
        self.description = description
        self.title = title
        self.isManagedByMacOS = isManagedByMacOS
        self.barPosition = barPosition
        self.orderKeyIsCertain = orderKeyIsCertain
        self.systemItem = systemItem
    }
}
