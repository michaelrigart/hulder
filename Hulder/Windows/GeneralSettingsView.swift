import AppKit
import HulderCore
import SwiftUI

import enum HulderCore.Section

struct GeneralSettingsView: View {
    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    let state: StateModel
    let menuBar: MenuBarModel
    let loginItem: LoginItem
    /// Suspends the global hotkeys while a recorder is recording and registers them again after.
    let setHotkeysSuspended: (Bool) -> Void

    @State private var recording: HotkeySlot?
    /// The message for the hotkey that was last refused, by slot.
    @State private var hotkeyProblem: [HotkeySlot: String] = [:]

    var body: some View {
        let settings = state.state.settings
        Form {
            SwiftUI.Section {
                Toggle("Launch at login", isOn: setting(\.launchAtLogin))
                if settings.launchAtLogin && loginItem.turnedOffInSystemSettings {
                    HStack {
                        Text("Turned off in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items Settings", action: Self.openLoginItems)
                    }
                }
                Picker("Default section for new apps", selection: defaultSection) {
                    ForEach([Section.visible, .hidden, .alwaysHidden], id: \.self) { Text($0.title).tag($0) }
                }
            }
            SwiftUI.Section("Hiding") {
                let note = menuBar.capabilities.rehideNote
                Picker("Hide again after", selection: setting(\.rehideDelay)) {
                    ForEach(RehideDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(note != nil)
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("Hotkeys") {
                ForEach(HotkeySlot.allCases, id: \.self) { hotkeyRow($0, settings: settings) }
            }
        }
        .formStyle(.grouped)
        .task { await loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loginItem.refresh() }
        }
        .onDisappear {
            recording = nil
            setHotkeysSuspended(false)
        }
    }

    private func hotkeyRow(_ slot: HotkeySlot, settings: HulderSettings) -> some View {
        let hotkey = settings.hotkey(for: slot)
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent(slot.action) {
                HStack {
                    HotkeyRecorder(
                        hotkey: hotkey, accessibilityLabel: slot.action, isRecording: recording == slot,
                        onRecordingChange: { setRecording($0, for: slot) },
                        onRecord: { record($0, $1, for: slot) },
                        onCancel: { hotkeyProblem[slot] = nil })
                        .fixedSize()
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        hotkeyProblem[slot] = nil
                        setRecording(false, for: slot)
                        state.update { $0.setHotkey(nil, for: slot) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(slot.action) shortcut")
                    .disabled(hotkey == nil)
                }
            }
            if let problem = hotkeyProblem[slot] {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The hotkeys are suspended and resumed here, in the same turn as the change, so neither waits
    /// for a window that is closing to update its views.
    private func setRecording(_ isRecording: Bool, for slot: HotkeySlot) {
        if isRecording {
            recording = slot
            setHotkeysSuspended(true)
        } else if recording == slot {
            recording = nil
            setHotkeysSuspended(false)
        }
    }

    private func record(_ keyCode: UInt32, _ modifiers: Hotkey.Modifiers, for slot: HotkeySlot) {
        switch HotkeyRules.choose(keyCode: keyCode, modifiers: modifiers, for: slot, in: state.state.settings) {
        case .accepted(let hotkey):
            hotkeyProblem[slot] = nil
            state.update { $0.setHotkey(hotkey, for: slot) }
        case .refused(let text):
            hotkeyProblem[slot] = text
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<HulderSettings, Value>) -> Binding<Value> {
        Binding(
            get: { state.state.settings[keyPath: keyPath] },
            set: { value in state.update { $0[keyPath: keyPath] = value } })
    }

    private var defaultSection: Binding<Section> {
        Binding(get: { state.state.layout.defaultSection }, set: { state.setDefaultSection($0) })
    }

    private static func openLoginItems() {
        guard let url = loginItemsSettings else { return }
        NSWorkspace.shared.open(url)
    }
}
