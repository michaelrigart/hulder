import ApplicationServices
import Darwin
import os

/// The Accessibility side of menu tracking: one observer per app, and a read of an app's windows.
final class MenuWindowSource27: MenuWindowSource {
    static let notifications = [
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
    ]

    private let subscribers = OSAllocatedUnfairLock<[UUID: AsyncStream<pid_t>.Continuation]>(initialState: [:])
    private let observers = OSAllocatedUnfairLock<Observers>(initialState: Observers())
    private let barEdges: BarBottomEdges27
    private let timeout: Float
    private let registrar: AXAppObserver.Registrar

    init(barEdges: BarBottomEdges27, timeout: Float, registrar: AXAppObserver.Registrar = .system) {
        self.barEdges = barEdges
        self.timeout = timeout
        self.registrar = registrar
    }

    func events() -> AsyncStream<pid_t> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers.withLock { $0[id] = continuation }
            continuation.onTermination = { [subscribers] _ in subscribers.withLock { $0[id] = nil } }
        }
    }

    private struct Observers {
        var next: UInt64 = 0
        var byToken: [MenuObserverToken: AXAppObserver] = [:]
    }

    func attach(_ pid: pid_t) -> MenuObserverToken? {
        let subscribers = subscribers
        let broadcast: @Sendable (pid_t) -> Void = { pid in
            subscribers.withLock { $0.values }.forEach { $0.yield(pid) }
        }
        guard let observer = AXAppObserver.attach(
            pid: pid, notifications: Self.notifications, timeout: timeout, registrar: registrar, handler: broadcast)
        else { return nil }
        return observers.withLock { observers in
            observers.next += 1
            let token = MenuObserverToken(rawValue: observers.next)
            observers.byToken[token] = observer
            return token
        }
    }

    func detach(_ token: MenuObserverToken) {
        observers.withLock { $0.byToken.removeValue(forKey: token) }?.invalidate()
    }

    /// Open while the app shows an `AXMenu` that has a size (on the app, or under one of its status items; a closed
    /// status item keeps a 0x0 one), or a window that isn't a standard window sits at the bottom edge of the menu
    /// bar of the screen it is on. A read that fails counts as closed.
    func isOpen(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let edges = barEdges.value
        for window in children(app, kAXWindowsAttribute) {
            AXUIElementSetMessagingTimeout(window, timeout)
            guard case .value(let value?) = ExtrasMenuBarReader.copyValue(window, "AXFrame"),
                  let frame = ExtrasMenuBarReader.rect(from: value),
                  WindowRule.isAnchored(frame: frame, edges: edges) else { continue }
            let subrole = ExtrasMenuBarReader.copyValue(window, kAXSubroleAttribute)
            if case .value(let value) = subrole, WindowRule.isOpen(subrole: value as? String, frame: frame, edges: edges) {
                return true
            }
        }
        if children(app, kAXChildrenAttribute).contains(where: isOpenMenu) { return true }
        if case .value(let value?) = ExtrasMenuBarReader.copyValue(app, kAXExtrasMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            let bar = unsafeDowncast(value, to: AXUIElement.self)
            for item in children(bar, kAXChildrenAttribute) where children(item, kAXChildrenAttribute).contains(where: isOpenMenu) {
                return true
            }
        }
        return false
    }

    private func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, timeout)
        guard case .value(let value?) = ExtrasMenuBarReader.copyValue(element, attribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// An `AXMenu` that is showing.
    private func isOpenMenu(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout)
        guard case .value(let value?) = ExtrasMenuBarReader.copyValue(element, kAXRoleAttribute),
              (value as? String) == kAXMenuRole else { return false }
        return MenuRule.isOpen(size: size(of: element) ?? .zero)
    }

    /// The element's `AXSize`, or the size of its `AXFrame` when it has no `AXSize`.
    private func size(of element: AXUIElement) -> CGSize? {
        if case .value(let value?) = ExtrasMenuBarReader.copyValue(element, kAXSizeAttribute),
           CFGetTypeID(value) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) { return size }
        }
        if case .value(let value?) = ExtrasMenuBarReader.copyValue(element, "AXFrame") {
            return ExtrasMenuBarReader.rect(from: value)?.size
        }
        return nil
    }
}
