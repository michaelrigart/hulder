public struct SystemItemID: Hashable, Comparable, Codable, Sendable {
    public let moduleName: String

    public init(moduleName: String) {
        self.moduleName = moduleName
    }

    public init(from decoder: any Decoder) throws {
        moduleName = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(moduleName)
    }

    public static func < (lhs: SystemItemID, rhs: SystemItemID) -> Bool {
        lhs.moduleName < rhs.moduleName
    }
}

public enum AssignableUnit: Hashable, Sendable {
    case app(AppID)
    case systemItem(SystemItemID)
}

public enum AppleOwners {
    public static let systemUIServer = AppID("com.apple.systemuiserver")
    public static let textInputMenuAgent = AppID("com.apple.TextInputMenuAgent")
    public static let menuBarAgent = AppID("com.apple.MenuBarAgent")
    public static let controlCenter = AppID("com.apple.controlcenter")

    public static let assignable: Set<AppID> = [systemUIServer, textInputMenuAgent]

    public static let all: Set<AppID> = assignable.union([menuBarAgent, controlCenter])

    /// The SF Symbol that stands in for an Apple owner's icon, since it is a background agent with none: the keyboard
    /// for the Input Menu's owner, else the generic menu bar. Nil for any other app.
    public static func symbolName(of owner: AppID) -> String? {
        guard all.contains(owner) else { return nil }
        return owner == textInputMenuAgent ? "keyboard" : "menubar.rectangle"
    }
}
