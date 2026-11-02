import AppKit
import Carbon.HIToolbox
import HulderCore
import SwiftUI

/// A button that records one key with modifiers. Clicking it (or pressing Space on it) starts recording;
/// the next key press is reported to `onRecord`, and Esc on its own stops. It records only: the rules
/// are `HotkeyRules`.
struct HotkeyRecorder: NSViewRepresentable {
    let hotkey: Hotkey?
    let accessibilityLabel: String
    /// Called with the key code and modifiers of a key press, so the caller can accept or refuse it.
    let onRecord: (UInt32, Hotkey.Modifiers) -> Void
    /// Called when recording starts and when Esc stops it, so a stale message can go.
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = onRecord
        button.onCancel = onCancel
        button.shown = hotkey.map { HotkeyRules.describe($0, keyName: KeyLayout.character(for:)) }
    }
}

final class RecorderButton: NSButton {
    var onRecord: ((UInt32, Hotkey.Modifiers) -> Void)?
    var onCancel: (() -> Void)?
    var shown: String? { didSet { refreshTitle() } }
    private var recording = false { didSet { refreshTitle() } }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func toggleRecording() {
        if recording {
            recording = false
        } else {
            recording = true
            window?.makeFirstResponder(self)
            onCancel?()
        }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    // ⌘-combinations reach the menu before keyDown; while recording they are the user's input.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    private func record(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let modifiers = Hotkey.Modifiers(event.modifierFlags)
        recording = false
        if HotkeyRules.cancels(keyCode: keyCode, modifiers: modifiers) {
            onCancel?()
        } else {
            onRecord?(keyCode, modifiers)
        }
    }

    private func refreshTitle() {
        title = recording ? "Type shortcut…" : (shown ?? "Record shortcut")
        setAccessibilityValue(recording ? "Recording" : (shown ?? "Not set"))
    }
}

extension Hotkey.Modifiers {
    /// The device-independent modifier flags of a key event, as Carbon's flags.
    init(_ flags: NSEvent.ModifierFlags) {
        var result: Hotkey.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

/// The character a key code types on the current keyboard layout.
enum KeyLayout {
    @MainActor
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, "TISPropertyUnicodeKeyLayoutData" as CFString)
        else { return nil }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
