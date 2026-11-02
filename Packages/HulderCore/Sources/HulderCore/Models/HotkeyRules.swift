import Foundation

public enum HotkeySlot: Sendable, CaseIterable {
    case toggle
    case revealAll

    public var action: String {
        switch self {
        case .toggle: "Show or hide icons"
        case .revealAll: "Show all icons"
        }
    }
}

extension Hotkey {
    /// Carbon's modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), which is what
    /// `RegisterEventHotKey` reads from `Hotkey.modifiers`.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)
    }
}

extension HulderSettings {
    public func hotkey(for slot: HotkeySlot) -> Hotkey? {
        switch slot {
        case .toggle: toggleHotkey
        case .revealAll: revealAllHotkey
        }
    }

    public mutating func setHotkey(_ hotkey: Hotkey?, for slot: HotkeySlot) {
        switch slot {
        case .toggle: toggleHotkey = hotkey
        case .revealAll: revealAllHotkey = hotkey
        }
    }
}

public enum HotkeyChoice: Equatable, Sendable {
    case accepted(Hotkey)
    /// The text is fixed by Hulder and safe to show.
    case refused(String)
}

public enum HotkeyRules {
    static let escapeKeyCode: UInt32 = 53

    /// A global hotkey needs ⌘, ⌥ or ⌃, and may not repeat the other hotkey's combination.
    public static func choose(
        keyCode: UInt32, modifiers: Hotkey.Modifiers, for slot: HotkeySlot, in settings: HulderSettings
    ) -> HotkeyChoice {
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else {
            return .refused("Use ⌘, ⌥ or ⌃ with the key.")
        }
        let hotkey = Hotkey(keyCode: keyCode, modifiers: modifiers.rawValue)
        if let other = HotkeySlot.allCases.first(where: { $0 != slot && settings.hotkey(for: $0) == hotkey }) {
            return .refused("Already used for \(other.action).")
        }
        return .accepted(hotkey)
    }

    /// Esc on its own stops the recording. With a modifier it is a key like any other.
    public static func cancels(keyCode: UInt32, modifiers: Hotkey.Modifiers) -> Bool {
        keyCode == escapeKeyCode && modifiers.isEmpty
    }

    /// "⌃⌥⇧⌘H". `keyName` gives the character a key code types on the current layout; keys without a
    /// character have names here.
    public static func describe(_ hotkey: Hotkey, keyName: (UInt32) -> String?) -> String {
        let modifiers = Hotkey.Modifiers(rawValue: hotkey.modifiers)
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let key = specialKeys[hotkey.keyCode] ?? keyName(hotkey.keyCode)?.uppercased() ?? "Key \(hotkey.keyCode)"
        return text + key
    }

    private static let specialKeys: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 76: "Enter", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]
}
