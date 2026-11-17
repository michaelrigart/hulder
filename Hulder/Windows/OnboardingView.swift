import AppKit
import SwiftUI

struct OnboardingView: View {
    /// Hulder runs from outside `/Applications`, so it hides nothing and asks for no permission.
    let needsMove: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if needsMove {
                Text("Move Hulder to the Applications folder, then open it again.")
                    .font(.headline)
            } else {
                Text("Hulder needs permission to see which apps have menu bar items.")
                    .font(.headline)
                Text("Turn on Hulder in System Settings › Privacy & Security › Device Control and Data Access.")
                HStack {
                    Button("Ask for Permission", action: AccessibilityPrompt.ask)
                        .keyboardShortcut(.defaultAction)
                    Button("Open System Settings", action: AccessibilityPrompt.openSettings)
                }
                Text("""
                    Hulder restarts itself once it sees the permission. If this window stays open after you turn \
                    Hulder on, Reopen Hulder finishes it.
                    """)
                    .foregroundStyle(.secondary)
                Button("Reopen Hulder") { Relaunch.perform() }
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
