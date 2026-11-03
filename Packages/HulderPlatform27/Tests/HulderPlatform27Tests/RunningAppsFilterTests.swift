import AppKit
import Testing
import HulderCore
@testable import HulderPlatform27

@Test func agentAndHelperAppsCount() {
    let apps: [(bundleID: String?, policy: Int)] = [
        ("com.example.regular", NSApplication.ActivationPolicy.regular.rawValue),
        ("com.example.agent", NSApplication.ActivationPolicy.accessory.rawValue),
        ("com.example.helper", NSApplication.ActivationPolicy.prohibited.rawValue),
        (nil, NSApplication.ActivationPolicy.regular.rawValue),
    ]
    #expect(RunningAppsFilter.appIDs(apps) == [
        AppID("com.example.regular"), AppID("com.example.agent"), AppID("com.example.helper"),
    ])
}
