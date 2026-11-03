/// What the global hotkeys should be registered as, and when. It decides which registrations to make and
/// drop; the caller makes them and reports a refusal. Suspending drops every registration, so a key
/// recorder sees the combinations they would take; resuming makes them again from the latest settings.
public struct HotkeyRegistrations: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case register(HotkeySlot, Hotkey)
        case unregister(HotkeySlot)
    }

    /// The hotkeys the settings ask for, whether or not they are registered now.
    private var desired: [HotkeySlot: Hotkey] = [:]
    /// The hotkey last tried for each slot, even when macOS refused it, so a refused one isn't tried
    /// again until its setting changes or the registrations are suspended and resumed.
    private var attempted: [HotkeySlot: Hotkey] = [:]
    private var registered: Set<HotkeySlot> = []
    private var suspended = false

    public init() {}

    public mutating func apply(toggle: Hotkey?, revealAll: Hotkey?) -> [Step] {
        desired[.toggle] = toggle
        desired[.revealAll] = revealAll
        return reconcile()
    }

    /// Drops every registration. It may be called again before `resume()`.
    public mutating func suspend() -> [Step] {
        guard !suspended else { return [] }
        suspended = true
        attempted.removeAll()
        let steps = HotkeySlot.allCases.filter(registered.contains).map(Step.unregister)
        registered.removeAll()
        return steps
    }

    /// Registers the desired hotkeys, once however many times `suspend()` was called.
    public mutating func resume() -> [Step] {
        guard suspended else { return [] }
        suspended = false
        return reconcile()
    }

    /// The caller could not register the slot's hotkey, as the last `register` step asked.
    public mutating func registrationFailed(_ slot: HotkeySlot) {
        registered.remove(slot)
    }

    private mutating func reconcile() -> [Step] {
        guard !suspended else { return [] }
        var steps: [Step] = []
        for slot in HotkeySlot.allCases where attempted[slot] != desired[slot] {
            attempted[slot] = desired[slot]
            if registered.remove(slot) != nil { steps.append(.unregister(slot)) }
            if let hotkey = desired[slot] {
                steps.append(.register(slot, hotkey))
                registered.insert(slot)
            }
        }
        return steps
    }
}
