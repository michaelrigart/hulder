import Testing
import HulderCore
@testable import HulderPlatform27

@Test func translatesAllowList() {
    let list = AllowList(apps: [AppID("com.example.b"), AppID("com.example.a")], keepsAllSystemItems: true)
    let arguments = AllowListTranslation.arguments(for: list)
    #expect(arguments.bundleIDs == ["com.example.a", "com.example.b"])
    #expect(arguments.systemItems == Array(0...127))
}
