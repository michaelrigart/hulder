import AppKit
import HulderCore
import SwiftUI

/// Asks for access to the order file and shows why reordering is unavailable. It decides nothing:
/// whether access exists comes from `OrderAccess`, and the reason from the capabilities.
struct ReorderingAccessView: View {
    let menuBar: MenuBarModel
    let access: (any OrderAccess)?

    @State private var granted: Bool?
    @State private var picking = false
    @State private var problem: String?

    var body: some View {
        content
            .task(id: menuBar.capabilities.reordering) { granted = await access?.isGranted() }
    }

    @ViewBuilder
    private var content: some View {
        if let access, granted == false {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Reordering needs access to the menu bar order file.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow reordering…") { allow(access) }
                        .disabled(picking)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        } else if access == nil || granted == true, case .unavailable(let reason) = menuBar.capabilities.reordering {
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private func allow(_ access: any OrderAccess) {
        picking = true
        problem = nil
        Task {
            defer { picking = false }
            guard let url = await Self.pickFolder(startingAt: access.suggestedLocation.deletingLastPathComponent())
            else { return }
            do {
                try await access.grant(pickedURL: url)
                granted = await access.isGranted()
            } catch {
                problem = Self.text(for: error)
            }
        }
    }

    /// The folder itself is protected, so the panel starts at its parent and the user picks it there.
    private static func pickFolder(startingAt directory: URL) async -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the com.apple.MenuBar folder, then click Allow."
        panel.prompt = "Allow"
        return await panel.begin() == .OK ? panel.url : nil
    }

    private static func text(for error: any Error) -> String {
        switch error as? OrderStoreError {
        case .unsupportedFormat(let text)?: text
        case .noAccess?: "Hulder couldn't open that folder."
        default: "Hulder couldn't set up reordering."
        }
    }
}
