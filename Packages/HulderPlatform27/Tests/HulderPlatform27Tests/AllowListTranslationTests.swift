import Testing
import HulderCore
@testable import HulderPlatform27

@Test func translatesAllowList() {
    let list = AllowList(apps: [AppID("com.example.b"), AppID("com.example.a")])
    let arguments = AllowListTranslation.arguments(for: list)
    #expect(arguments.bundleIDs == ["com.example.a", "com.example.b"])
    #expect(arguments.systemItems == Array(0...127))
}

// Catches a translation that ignores the hidden modules: they would stay on the bar.
@Test func hiddenModulesLeaveTheirNumbersOutOfTheSystemItems() {
    let apps: Set<AppID> = [AppID("com.example.a")]
    #expect(AllowListTranslation.arguments(for: AllowList(apps: apps)).systemItems == Array(0...127))

    let wifi = AllowListTranslation.arguments(for: AllowList(apps: apps, hiddenSystemItems: [SystemItemID(moduleName: "WiFi")]))
    #expect(wifi.systemItems == Array(0...127).filter { $0 != 6 })

    let two = AllowListTranslation.arguments(
        for: AllowList(apps: apps, hiddenSystemItems: [SystemItemID(moduleName: "Battery"), SystemItemID(moduleName: "BentoBox")]))
    #expect(two.systemItems == Array(0...127).filter { $0 != 0 && $0 != 8 })
}

// Catches a module without a number being guessed: nothing is removed for it.
@Test func aModuleTheTableDoesNotKnowRemovesNothing() {
    let list = AllowList(apps: [], hiddenSystemItems: [SystemItemID(moduleName: "Sound")])
    #expect(AllowListTranslation.arguments(for: list).systemItems == Array(0...127))
}

@Test func theTableMapsIdentifiersToModulesAndNumbers() throws {
    let wifi = try #require(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.wifi"))
    #expect(wifi.id == SystemItemID(moduleName: "WiFi") && wifi.number == 6 && wifi.orderName == "WiFi")
    let center = try #require(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.CONTROLCENTER"))
    #expect(center.id == SystemItemID(moduleName: "BentoBox") && center.number == 8 && center.orderName == "BentoBox")
    #expect(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.battery")?.number == 0)
    #expect(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.clock")?.number == 2)
    #expect(SystemItemTable27.entry(forIdentifier: "com.apple.menuextra.focusmode") == nil)
    #expect(SystemItemTable27.entry(forIdentifier: nil) == nil)
    #expect(SystemItemTable27.number(for: SystemItemID(moduleName: "Clock")) == 2)
    #expect(SystemItemTable27.number(for: SystemItemID(moduleName: "Sound")) == nil)
}
