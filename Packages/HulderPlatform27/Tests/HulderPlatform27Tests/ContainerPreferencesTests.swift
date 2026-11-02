import Foundation
import HulderCore
import Testing
@testable import HulderPlatform27

/// A lookup whose pointers would crash if called, so no test reaches the real preferences.
private func lookup(missing: String?) -> ContainerPreferences.SymbolLookup {
    { $0 == missing ? nil : UnsafeMutableRawPointer(bitPattern: 1) }
}

@Test func aMissingPreferencesFunctionIsNeverCalled() {
    let preferences = ContainerPreferences(
        container: URL(filePath: "/nonexistent/com.apple.MenuBar"), lookup: lookup(missing: ContainerPreferences.setSymbol)
    )
    #expect(preferences.availability == .unavailable("_CFPreferencesSetAppValueWithContainer missing"))
    #expect(preferences.copyPositions() == nil)
    #expect(!preferences.setPositions([:]))
}

@Test func theContainerPathHasNoTrailingSlash() {
    let folder = URL(filePath: "/nonexistent/com.apple.MenuBar/", directoryHint: .isDirectory)
    let preferences = ContainerPreferences(container: folder, lookup: lookup(missing: nil))
    #expect(preferences.availability == .available)
    #expect(preferences.containerPath == "/nonexistent/com.apple.MenuBar")
}
