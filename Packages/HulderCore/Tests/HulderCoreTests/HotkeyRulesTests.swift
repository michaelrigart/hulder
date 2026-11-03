import Foundation
import Testing
@testable import HulderCore

struct HotkeyRulesTests {
    private let keyH: UInt32 = 4

    @Test func modifierFlagsAreCarbonsValues() {
        // HotkeyCenter hands Hotkey.modifiers to RegisterEventHotKey, which reads Carbon's cmdKey (256),
        // shiftKey (512), optionKey (2048) and controlKey (4096).
        #expect(Hotkey.Modifiers.command.rawValue == 256)
        #expect(Hotkey.Modifiers.shift.rawValue == 512)
        #expect(Hotkey.Modifiers.option.rawValue == 2048)
        #expect(Hotkey.Modifiers.control.rawValue == 4096)
    }

    @Test func aKeyWithCommandOptionOrControlIsAccepted() {
        let settings = HulderSettings()

        for modifier: Hotkey.Modifiers in [.command, .option, .control] {
            let choice = HotkeyRules.choose(keyCode: keyH, modifiers: [modifier, .shift], for: .toggle, in: settings)
            #expect(choice == .accepted(Hotkey(keyCode: keyH, modifiers: modifier.union(.shift).rawValue)))
        }
    }

    @Test func aKeyWithoutCommandOptionOrControlIsRefused() {
        let settings = HulderSettings()

        #expect(HotkeyRules.choose(keyCode: keyH, modifiers: [], for: .toggle, in: settings)
            == .refused("Use ⌘, ⌥ or ⌃ with the key."))
        #expect(HotkeyRules.choose(keyCode: keyH, modifiers: [.shift], for: .toggle, in: settings)
            == .refused("Use ⌘, ⌥ or ⌃ with the key."))
    }

    @Test func aCombinationTheOtherHotkeyUsesIsRefusedNamingItsAction() {
        var settings = HulderSettings()
        settings.revealAllHotkey = Hotkey(keyCode: keyH, modifiers: Hotkey.Modifiers.command.rawValue)
        settings.toggleHotkey = Hotkey(keyCode: 5, modifiers: Hotkey.Modifiers.option.rawValue)

        #expect(HotkeyRules.choose(keyCode: keyH, modifiers: [.command], for: .toggle, in: settings)
            == .refused("Already used for Show all icons."))
        #expect(HotkeyRules.choose(keyCode: 5, modifiers: [.option], for: .revealAll, in: settings)
            == .refused("Already used for Show or hide icons."))
    }

    @Test func aHotkeyMayBeRecordedAgainOverItself() {
        var settings = HulderSettings()
        settings.toggleHotkey = Hotkey(keyCode: keyH, modifiers: Hotkey.Modifiers.command.rawValue)

        #expect(HotkeyRules.choose(keyCode: keyH, modifiers: [.command], for: .toggle, in: settings)
            == .accepted(Hotkey(keyCode: keyH, modifiers: Hotkey.Modifiers.command.rawValue)))
    }

    @Test func escapeWithoutModifiersCancelsAndWithOneIsARegularKey() {
        #expect(HotkeyRules.cancels(keyCode: 53, modifiers: []))
        #expect(HotkeyRules.cancels(keyCode: 53, modifiers: [.shift]) == false)
        #expect(HotkeyRules.cancels(keyCode: 53, modifiers: [.command]) == false)
        #expect(HotkeyRules.cancels(keyCode: keyH, modifiers: []) == false)
    }

    @Test func settingsReadAndWriteEachSlot() {
        var settings = HulderSettings()
        let hotkey = Hotkey(keyCode: keyH, modifiers: Hotkey.Modifiers.control.rawValue)

        settings.setHotkey(hotkey, for: .revealAll)

        #expect(settings.hotkey(for: .revealAll) == hotkey)
        #expect(settings.revealAllHotkey == hotkey)
        #expect(settings.hotkey(for: .toggle) == nil)

        settings.setHotkey(nil, for: .revealAll)
        #expect(settings.revealAllHotkey == nil)
    }

    @Test func aHotkeyReadsAsModifierSymbolsThenTheKey() {
        let all = Hotkey.Modifiers([.control, .option, .shift, .command]).rawValue

        #expect(HotkeyRules.describe(Hotkey(keyCode: keyH, modifiers: all), keyName: { _ in "h" }) == "⌃⌥⇧⌘H")
        #expect(HotkeyRules.describe(Hotkey(keyCode: 49, modifiers: Hotkey.Modifiers.command.rawValue), keyName: { _ in nil })
            == "⌘Space")
        #expect(HotkeyRules.describe(Hotkey(keyCode: 122, modifiers: Hotkey.Modifiers.option.rawValue), keyName: { _ in nil })
            == "⌥F1")
        #expect(HotkeyRules.describe(Hotkey(keyCode: 99, modifiers: Hotkey.Modifiers.option.rawValue), keyName: { _ in nil })
            == "⌥F3")
        #expect(HotkeyRules.describe(Hotkey(keyCode: 200, modifiers: Hotkey.Modifiers.option.rawValue), keyName: { _ in nil })
            == "⌥Key 200")
    }
}
