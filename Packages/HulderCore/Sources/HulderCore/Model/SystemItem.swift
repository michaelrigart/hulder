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
    public static let assignable: Set<AppID> = [
        AppID("com.apple.systemuiserver"), AppID("com.apple.TextInputMenuAgent"),
    ]

    public static let all: Set<AppID> = assignable.union([
        AppID("com.apple.MenuBarAgent"), AppID("com.apple.controlcenter"),
    ])
}
