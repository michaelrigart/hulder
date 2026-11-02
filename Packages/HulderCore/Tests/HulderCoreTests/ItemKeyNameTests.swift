import Testing
@testable import HulderCore

struct ItemKeyNameTests {
    private func name(_ raw: String) -> String? { ItemKey(raw: raw).derivedName }

    private func item(_ raw: String, owner: String = "MenuBarAgent", description: String? = nil, title: String? = nil) -> MenuBarItem {
        MenuBarItem(
            key: ItemKey(raw: raw), owner: .app(AppID("com.apple.MenuBarAgent"), name: owner), description: description, title: title)
    }

    // Catches the Layout list showing every Apple item as "MenuBarAgent".
    @Test func aKnownModuleHasItsMenuBarName() {
        #expect(name("module:WiFi") == "Wi-Fi")
        #expect(name("module:BentoBox-0") == "Control Center")
        #expect(name("module:FocusModes") == "Focus")
        #expect(name("module:NowPlaying") == "Now Playing")
        #expect(name("module:ScreenMirroring") == "Screen Mirroring")
        #expect(name("module:AudioVideoModule") == "Audio and Video")
    }

    @Test func anUnknownModuleHasItsNameWithCamelCaseWordsSplit() {
        #expect(name("module:Battery") == "Battery")
        #expect(name("module:Clock") == "Clock")
        #expect(name("module:Sound") == "Sound")
        #expect(name("module:Display") == "Display")
        #expect(name("module:UserSwitcher") == "User Switcher")
    }

    @Test func aTrailingNumberIsDroppedFromAModuleName() {
        #expect(name("module:Battery-2") == "Battery")
        #expect(name("module:BentoBox-12") == "Control Center")
        #expect(name("module:Part-A") == "Part-A")
    }

    @Test func aStatusKeyNamesTheItemAfterItsAutosaveName() {
        #expect(name("status:com.apple.systemuiserver::Siri") == "Siri")
    }

    @Test func anItemNumberOrAUUIDIsNotAName() {
        #expect(name("status:com.example.app::Item-0") == nil)
        #expect(name("status:com.example.app::Item-12") == nil)
        #expect(name("status:com.example.app::6F9619FF-8B86-D011-B42D-00C04FC964FF") == nil)
        #expect(name("status:com.example.app::") == nil)
        #expect(name("module:") == nil)
        #expect(name("something-else") == nil)
    }

    @Test func aModuleWithNoDescriptionOrTitleIsLabelledWithItsNameAlone() {
        #expect(item("module:WiFi").label == "Wi-Fi")
        #expect(item("module:Clock").label == "Clock")
    }

    @Test func aStatusItemWithNoDescriptionOrTitleIsLabelledWithItsAppAndItsName() {
        #expect(item("status:com.apple.systemuiserver::Siri", owner: "SystemUIServer").label == "SystemUIServer: Siri")
        #expect(item("status:com.example.app::Item-0", owner: "Alpha").label == "Alpha")
    }

    @Test func aDescriptionOrTitleWinsOverTheDerivedName() {
        #expect(item("module:WiFi", description: "Wi-Fi status").label == "MenuBarAgent: Wi-Fi status")
        #expect(item("module:WiFi", title: "Network").label == "MenuBarAgent: Network")
        #expect(item("status:com.apple.systemuiserver::Siri", owner: "SystemUIServer", description: "Ask").label == "SystemUIServer: Ask")
    }
}
