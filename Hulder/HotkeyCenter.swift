import Carbon.HIToolbox
import HulderCore

/// Registers the two global hotkeys through `RegisterEventHotKey`. A `Hotkey`'s modifiers are Carbon
/// modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
@MainActor
final class HotkeyCenter {
    private static let signature: OSType = 0x484C_4452

    private let onToggle: @MainActor () -> Void
    private let onRevealAll: @MainActor () -> Void
    /// What to register and when. This type only makes the Carbon calls it asks for.
    private var registrations = HotkeyRegistrations()
    private var references: [HotkeySlot: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init(onToggle: @escaping @MainActor () -> Void, onRevealAll: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        self.onRevealAll = onRevealAll
    }

    /// Registers each hotkey that is set and drops each that is not. One that has not changed is left alone.
    func apply(toggle: Hotkey?, revealAll: Hotkey?) {
        installHandler()
        run(registrations.apply(toggle: toggle, revealAll: revealAll))
    }

    /// Unregisters both hotkeys, so a key recorder sees the combinations the hotkeys would take. Every
    /// call is paired with `resume()`.
    func suspend() {
        run(registrations.suspend())
    }

    func resume() {
        run(registrations.resume())
    }

    fileprivate func fire(_ id: UInt32) {
        switch id {
        case Self.id(of: .toggle): onToggle()
        case Self.id(of: .revealAll): onRevealAll()
        default: break
        }
    }

    private static func id(of slot: HotkeySlot) -> UInt32 {
        slot == .toggle ? 1 : 2
    }

    private func run(_ steps: [HotkeyRegistrations.Step]) {
        for step in steps {
            switch step {
            case .unregister(let slot):
                if let old = references.removeValue(forKey: slot) { UnregisterEventHotKey(old) }
            case .register(let slot, let hotkey):
                register(slot, hotkey)
            }
        }
    }

    private func register(_ slot: HotkeySlot, _ hotkey: Hotkey) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.id(of: slot))
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.app.notice("A hotkey could not be registered (status \(status, privacy: .public))")
            registrations.registrationFailed(slot)
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
