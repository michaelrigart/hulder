import AppKit
import SwiftUI

struct OnboardingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hulder needs permission to see which apps have menu bar items.")
                .font(.headline)
            Text("Turn on Hulder in System Settings › Privacy & Security › Device Control and Data Access.")
            HStack {
                Button("Ask for Permission", action: AccessibilityPrompt.ask)
                    .keyboardShortcut(.defaultAction)
                Button("Open System Settings", action: AccessibilityPrompt.openSettings)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
