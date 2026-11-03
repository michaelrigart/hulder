import AppKit
import HulderCore
import SwiftUI

struct AboutSettingsView: View {
    let state: StateModel
    let menuBar: MenuBarModel

    @State private var copied = false

    var body: some View {
        Form {
            if let notice = menuBar.capabilities.unsupportedNotice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Version", value: Self.appVersion)
            }
            Section("Capabilities") {
                ForEach(menuBar.capabilities.lines) { line in
                    LabeledContent(line.name) {
                        Label(line.detail, systemImage: line.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(line.isAvailable ? Color.green : Color.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                LabeledContent("Settings file", value: state.storeStatus.title)
            }
            Section {
                HStack {
                    Button("Copy Diagnostics", action: copy)
                    if copied {
                        Text("Copied.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("The copy holds versions, capabilities, counts and recent failures. It has no app names and no file paths.")
            }
        }
        .formStyle(.grouped)
    }

    private func copy() {
        let report = DiagnosticsReport.make(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: Self.appVersion,
            layout: state.state.layout, menuBar: menuBar, storeStatus: state.storeStatus)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        AccessibilityNotification.Announcement("Diagnostics copied.").post()
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
