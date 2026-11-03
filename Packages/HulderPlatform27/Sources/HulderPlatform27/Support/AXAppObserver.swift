import ApplicationServices
import Dispatch

/// An `AXObserver` on one process's application element. Build it on an `AXQueue`: creating it and
/// registering the notifications block. Notifications arrive on the main run loop and only call `handler`,
/// which must be cheap and thread-safe.
final class AXAppObserver: @unchecked Sendable { // reason: the CF objects are set once; `invalidate` only touches the run loop source, on the main queue
    private final class Registration: Sendable {
        let pid: pid_t
        let handler: @Sendable (pid_t) -> Void

        init(pid: pid_t, handler: @escaping @Sendable (pid_t) -> Void) {
            self.pid = pid
            self.handler = handler
        }
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
        registration.handler(registration.pid)
    }

    /// How notifications are registered and removed, so a test can make one registration fail.
    struct Registrar: Sendable {
        var add: @Sendable (AXObserver, AXUIElement, String, UnsafeMutableRawPointer) -> AXError
        var remove: @Sendable (AXObserver, AXUIElement, String) -> AXError

        static let system = Registrar(
            add: { AXObserverAddNotification($0, $1, $2 as CFString, $3) },
            remove: { AXObserverRemoveNotification($0, $1, $2 as CFString) })
    }

    private let observer: AXObserver
    private let source: CFRunLoopSource
    private let registration: Registration

    private init(observer: AXObserver, source: CFRunLoopSource, registration: Registration) {
        self.observer = observer
        self.source = source
        self.registration = registration
    }

    /// Nil when the observer can't be created or any notification could not be registered: an observer that misses
    /// one would be reported as attached while it never delivers it. The ones that did register are removed again.
    static func attach(
        pid: pid_t,
        notifications: [String],
        timeout: Float,
        registrar: Registrar = .system,
        handler: @escaping @Sendable (pid_t) -> Void
    ) -> AXAppObserver? {
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let registration = Registration(pid: pid, handler: handler)
        let refcon = Unmanaged.passUnretained(registration).toOpaque()
        var registered: [String] = []
        for name in notifications where registrar.add(observer, app, name, refcon) == .success {
            registered.append(name)
        }
        guard registered.count == notifications.count else {
            for name in registered { _ = registrar.remove(observer, app, name) }
            return nil
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return AXAppObserver(observer: observer, source: source, registration: registration)
    }

    /// Stops delivery. Callbacks run on the main thread, so invalidating there means none is in flight
    /// when the registration is released.
    func invalidate() {
        DispatchQueue.main.async { CFRunLoopSourceInvalidate(self.source) }
    }
}
