import Testing
import HulderCore
@testable import HulderPlatform27

@Test func linksCore() {
    #expect(HulderCore.bundleID.hasSuffix("hulder"))
}
