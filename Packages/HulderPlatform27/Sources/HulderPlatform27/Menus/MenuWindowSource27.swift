import ApplicationServices
import Darwin
import os

/// The Accessibility side of menu tracking: one observer per app, and a read of an app's windows.
final class MenuWindowSource27: MenuWindowSource {
    static let notifications = [
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
    ]

    let events: AsyncStream<pid_t>
    private let continuation: AsyncStream<pid_t>.Continuation
    private let observers = OSAllocatedUnfairLock<[pid_t: AXAppObserver]>(initialState: [:])
    private let barEdge: BarBottomEdge27
    private let timeout: Float

    init(barEdge: BarBottomEdge27, timeout: Float) {
        (events, continuation) = AsyncStream<pid_t>.makeStream()
        self.barEdge = barEdge
        self.timeout = timeout
    }

    func attach(_ pid: pid_t) -> Bool {
        let continuation = continuation
        guard let observer = AXAppObserver.attach(pid: pid, notifications: Self.notifications, timeout: timeout, handler: { continuation.yield($0) }) else {
            return false
        }
        observers.withLock { $0.updateValue(observer, forKey: pid) }?.invalidate()
        return true
    }

    func detach(_ pid: pid_t) {
        observers.withLock { $0.removeValue(forKey: pid) }?.invalidate()
    }

    /// Open while the app shows an `AXMenu` (on the app, or under one of its status items), or a window sits at
    /// the bar's bottom edge. A read that fails counts as closed.
    func isOpen(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let edge = barEdge.value
        for window in children(app, kAXWindowsAttribute) {
            AXUIElementSetMessagingTimeout(window, timeout)
            if case .value(let value?) = ExtrasMenuBarReader.copyValue(window, "AXFrame"),
               let frame = ExtrasMenuBarReader.rect(from: value),
               WindowRule.isAnchored(top: frame.minY, barBottom: edge) {
                return true
            }
        }
        if children(app, kAXChildrenAttribute).contains(where: isMenu) { return true }
        if case .value(let value?) = ExtrasMenuBarReader.copyValue(app, kAXExtrasMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            let bar = unsafeDowncast(value, to: AXUIElement.self)
            for item in children(bar, kAXChildrenAttribute) where children(item, kAXChildrenAttribute).contains(where: isMenu) {
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

    private func isMenu(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout)
        guard case .value(let value?) = ExtrasMenuBarReader.copyValue(element, kAXRoleAttribute) else { return false }
        return (value as? String) == kAXMenuRole
    }
}
