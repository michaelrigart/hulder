import SwiftUI

struct LayoutLimitsView: View {
    static let limits = [
        "macOS hides whole apps, so all of an app's icons move between sections together.",
        "While anything is hidden, macOS also hides Focus, AirDrop, Now Playing, Control Center controls and the camera and microphone button. ⌥-click Hulder's icon to show everything.",
        "The clock and Control Center stay at the right end of the menu bar.",
        "Icons that show changing text can land next to where you put them.",
        "Apps outside the Applications folder may not show their icons while anything is hidden.",
        "On a crowded menu bar, macOS folds icons behind its own « button.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What macOS 27 doesn't allow")
                .font(.headline)
            ForEach(Self.limits, id: \.self) { limit in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(limit)
                }
                .accessibilityElement(children: .combine)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
