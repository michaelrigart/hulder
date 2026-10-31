public enum RehideDelay: String, Codable, CaseIterable, Sendable {
    case seconds5
    case seconds10
    case seconds30
    case seconds60
    case never

    public var duration: Duration? {
        switch self {
        case .seconds5: .seconds(5)
        case .seconds10: .seconds(10)
        case .seconds30: .seconds(30)
        case .seconds60: .seconds(60)
        case .never: nil
        }
    }
}

public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HulderSettings: Codable, Equatable, Sendable {
    public var launchAtLogin = true
    public var rehideDelay: RehideDelay = .seconds10
    public var toggleHotkey: Hotkey?
    public var revealAllHotkey: Hotkey?

    public init() {}
}
