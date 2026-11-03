import Testing
@testable import HulderCore

struct InstallLocationTests {
    @Test(arguments: [
        "/Applications/Hulder.app",
        "/Applications/../Applications/Hulder.app",
    ])
    func aBundleDirectlyInApplicationsIsSupported(path: String) {
        #expect(InstallLocation.isSupported(bundlePath: path))
    }

    @Test(arguments: [
        "/Applications/Utilities/Hulder.app",
        "/Users/x/Applications/Hulder.app",
        "/Users/x/Downloads/Hulder.app",
        "/Users/x/Code/hulder/build/Build/Products/Release/Hulder.app",
    ])
    func aBundleElsewhereIsNotSupported(path: String) {
        #expect(!InstallLocation.isSupported(bundlePath: path))
    }
}
