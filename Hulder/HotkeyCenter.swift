import Carbon.HIToolbox
import HulderCore

/// Registers the two global hotkeys through `RegisterEventHotKey`. A `Hotkey`'s modifiers are Carbon
/// modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
@MainActor
final class HotkeyCenter {
    private enum Slot: UInt32 {
        case toggle = 1
        case revealAll = 2
    }

    private static let signature: OSType = 0x484C_4452

    private let onToggle: @MainActor () -> Void
    private let onRevealAll: @MainActor () -> Void
    private var registered: [Slot: (key: Hotkey, ref: EventHotKeyRef)] = [:]
    private var handler: EventHandlerRef?

    init(onToggle: @escaping @MainActor () -> Void, onRevealAll: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        self.onRevealAll = onRevealAll
    }

    /// Registers each hotkey that is set and drops each that is not. One that has not changed stays registered.
    func apply(toggle: Hotkey?, revealAll: Hotkey?) {
        installHandler()
        update(.toggle, to: toggle)
        update(.revealAll, to: revealAll)
    }

    fileprivate func fire(_ id: UInt32) {
        switch Slot(rawValue: id) {
        case .toggle: onToggle()
        case .revealAll: onRevealAll()
        case nil: break
        }
    }

    private func update(_ slot: Slot, to hotkey: Hotkey?) {
        if registered[slot]?.key == hotkey { return }
        if let old = registered.removeValue(forKey: slot) {
            UnregisterEventHotKey(old.ref)
        }
        guard let hotkey else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.app.notice("A hotkey could not be registered (status \(status, privacy: .public))")
            return
        }
        registered[slot] = (hotkey, ref)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotkeyPressed, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            Log.app.notice("The hotkey handler could not be installed (status \(status, privacy: .public))")
        }
    }
}

private nonisolated func hotkeyPressed(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData)
    let slot = id.id
    // reason: the application event target delivers hotkey events on the main thread.
    MainActor.assumeIsolated {
        center.takeUnretainedValue().fire(slot)
    }
    return noErr
}
