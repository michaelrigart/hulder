import Testing
@testable import HulderCore

struct ItemKeyNameTests {
    private func name(_ raw: String) -> String? { ItemKey(raw: raw).derivedName }

    private func item(_ raw: String, owner: String = "MenuBarAgent", description: String? = nil, title: String? = nil,
        managed: Bool = false
    ) -> MenuBarItem {
        MenuBarItem(
            key: ItemKey(raw: raw), owner: .app(AppID("com.apple.MenuBarAgent"), name: owner), description: description, title: title,
            isManagedByMacOS: managed)
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

    // Catches the module rule drifting between the key builder and the display name.
    @Test func aModuleKeyGivesItsNameWithoutThePrefixAndTrailingNumber() {
        #expect(ItemKey(raw: "module:BentoBox-0").moduleName == "BentoBox")
        #expect(ItemKey(raw: "module:BentoBox-12").moduleName == "BentoBox")
        #expect(ItemKey(raw: "module:Clock").moduleName == "Clock")
        #expect(ItemKey(raw: "module:Part-A").moduleName == "Part-A")
        #expect(ItemKey(raw: "module:Part-").moduleName == "Part-")
        #expect(ItemKey(raw: "module:-3").moduleName == "")
        #expect(ItemKey(raw: "module:").moduleName == "")
    }

    @Test func aKeyThatIsNotAModuleHasNoModuleName() {
        #expect(ItemKey(raw: "status:com.apple.systemuiserver::Siri").moduleName == nil)
        #expect(ItemKey(raw: "Clock").moduleName == nil)
    }

    @Test func aStatusKeyNamesTheItemAfterItsAutosaveName() {
        #expect(name("status:com.apple.systemuiserver::Siri") == "Siri")
    }

    @Test func theInputMenuHasAppleName() {
        #expect(name("status:com.apple.TextInputMenuAgent::Item-0") == "Input Menu")
        #expect(name("status:com.apple.TextInputMenuAgent::Item-3") == "Input Menu")
        #expect(name("status:com.apple.TextInputMenuAgent::Other") == "Other")
        #expect(name("status:com.example.app::Item-0") == nil)
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
        #expect(item("module:WiFi", managed: true).label == "Wi-Fi")
        #expect(item("module:Clock", managed: true).label == "Clock")
    }

    @Test func aStatusItemWithNoDescriptionOrTitleIsLabelledWithItsAppAndItsName() {
        #expect(item("status:com.apple.systemuiserver::Siri", owner: "SystemUIServer").label == "SystemUIServer: Siri")
        #expect(item("status:com.example.app::Item-0", owner: "Alpha").label == "Alpha")
    }

    @Test func aDescriptionOrTitleWinsOverTheDerivedName() {
        #expect(item("status:com.example.app::Item-0", owner: "Alpha", title: "Tick").label == "Alpha: Tick")
        #expect(item("status:com.apple.systemuiserver::Siri", owner: "SystemUIServer", description: "Ask").label == "SystemUIServer: Ask")
    }

    // MenuBarAgent's modules are always managed by macOS, so their name wins over any description or title.
    @Test func aModuleKeepsItsNameWhateverItsDescriptionOrTitle() {
        #expect(item("module:WiFi", description: "Wi-Fi status", managed: true).label == "Wi-Fi")
        #expect(item("module:WiFi", title: "Network", managed: true).label == "Wi-Fi")
    }

    // Catches the Layout list showing "SystemUIServer: Siri", a process name that means nothing to the user.
    @Test func aManagedStatusItemIsLabelledWithoutItsProcessName() {
        #expect(item("status:com.apple.systemuiserver::Siri", owner: "SystemUIServer", managed: true).label == "Siri")
    }

    // Catches "TextInputMenuAgent: ABC-Azerty" for the input source menu.
    @Test func theInputMenuNameWinsOverItsDescriptionWhenManaged() {
        let input = item(
            "status:com.apple.TextInputMenuAgent::Item-0", owner: "TextInputMenuAgent", description: "ABC-Azerty", managed: true)
        #expect(input.label == "Input Menu")
    }

    @Test func aManagedItemWithNoKeyNameIsLabelledWithItsDescriptionAlone() {
        #expect(item("status:com.example.app::Item-0", owner: "Alpha", description: "Sync", managed: true).label == "Sync")
        #expect(item("status:com.example.app::Item-0", owner: "Alpha", title: "Tick", managed: true).label == "Tick")
        #expect(item("status:com.example.app::Item-0", owner: "Alpha", managed: true).label == "Alpha")
    }

    @Test func anUnmanagedItemKeepsItsAppPrefix() {
        #expect(item("status:com.example.app::Item-0", owner: "Alpha", description: "Sync").label == "Alpha: Sync")
    }
}
