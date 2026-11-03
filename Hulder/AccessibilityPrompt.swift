import AppKit

/// The Accessibility permission's two actions, shared by the welcome window and Settings › Permissions.
enum AccessibilityPrompt {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")

    // The literal is kAXTrustedCheckOptionPrompt's value; the SDK's global is a mutable `var`, which
    // strict concurrency refuses to read.
    static func ask() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        guard let settingsURL else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
