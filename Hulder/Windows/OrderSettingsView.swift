import HulderCore
import SwiftUI

struct OrderSettingsView: View {
    let menuBar: MenuBarModel
    let actions: LayoutActions

    @State private var restoring = false
    @State private var notice: LayoutNotice?

    var body: some View {
        Form {
            Section {
                Button("Restore the menu bar order from before Hulder's last change") { restore() }
                    .disabled(restoring)
                if let notice {
                    Label(notice.text, systemImage: notice.isProblem ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(notice.isProblem ? Color.red : Color.secondary)
                }
                if case .unavailable(let reason) = menuBar.capabilities.reordering {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Hulder keeps a copy of the order before each change and restores the newest.")
            }
        }
        .formStyle(.grouped)
    }

    private func restore() {
        restoring = true
        notice = nil
        Task {
            defer { restoring = false }
            let outcome = await actions.restoreOrder()
            notice = outcome.restoreNotice
            if let text = notice?.text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}
