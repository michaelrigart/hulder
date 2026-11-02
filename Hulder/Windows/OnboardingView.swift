import AppKit
import SwiftUI

struct OnboardingView: View {
    static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hulder needs permission to see which apps have menu bar items.")
                .font(.headline)
            Text("Turn on Hulder in System Settings › Privacy & Security › Device Control and Data Access.")
            HStack {
                Button("Ask for Permission", action: Self.askForPermission)
                    .keyboardShortcut(.defaultAction)
                Button("Open System Settings", action: Self.openSettings)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // The literal is kAXTrustedCheckOptionPrompt's value; the SDK's global is a mutable `var`, which
    // strict concurrency refuses to read.
    private static func askForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func openSettings() {
        guard let url = accessibilitySettings else { return }
        NSWorkspace.shared.open(url)
    }
}
