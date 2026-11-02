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
    /// The hotkey last tried for each slot, even when macOS refused it, so a refused one isn't tried again
    /// until the setting changes.
    private var attempted: [Slot: Hotkey] = [:]
    /// The hotkeys the settings ask for, whether or not they are registered now.
    private var desired: [Slot: Hotkey] = [:]
    private var suspended = false
    private var references: [Slot: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init(onToggle: @escaping @MainActor () -> Void, onRevealAll: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        self.onRevealAll = onRevealAll
    }

    /// Registers each hotkey that is set and drops each that is not. One that has not changed is left alone.
    func apply(toggle: Hotkey?, revealAll: Hotkey?) {
        installHandler()
        desired[.toggle] = toggle
        desired[.revealAll] = revealAll
        registerDesired()
    }

    /// Unregisters both hotkeys, so a key recorder sees the combinations the hotkeys would take. Every
    /// call is paired with `resume()`. `apply` keeps recording the settings meanwhile.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for slot in [Slot.toggle, .revealAll] {
            if let old = references.removeValue(forKey: slot) { UnregisterEventHotKey(old) }
        }
        attempted.removeAll()
    }

    /// Registers the hotkeys the settings ask for.
    func resume() {
        guard suspended else { return }
        suspended = false
        registerDesired()
    }

    private func registerDesired() {
        guard !suspended else { return }
        update(.toggle, to: desired[.toggle])
        update(.revealAll, to: desired[.revealAll])
    }

    fileprivate func fire(_ id: UInt32) {
        switch Slot(rawValue: id) {
        case .toggle: onToggle()
        case .revealAll: onRevealAll()
        case nil: break
        }
    }

    private func update(_ slot: Slot, to hotkey: Hotkey?) {
        if attempted[slot] == hotkey { return }
        attempted[slot] = hotkey
        if let old = references.removeValue(forKey: slot) {
            UnregisterEventHotKey(old)
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
        references[slot] = ref
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
