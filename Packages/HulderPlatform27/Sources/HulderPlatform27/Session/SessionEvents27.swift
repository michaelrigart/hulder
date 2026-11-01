import AppKit
import HulderCore

/// Sleep and screen-lock events, which end a reveal.
final class SessionEvents27: Sendable {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")

    func events() -> AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            let workspace = NSWorkspace.shared.notificationCenter
            let distributed = DistributedNotificationCenter.default()
            let observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = [
                NSWorkspace.willSleepNotification,
                NSWorkspace.screensDidSleepNotification,
            ].map { name in
                (workspace, workspace.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield(.lockedOrAsleep) })
            } + [
                (distributed, distributed.addObserver(forName: Self.screenLocked, object: nil, queue: nil) { _ in
                    continuation.yield(.lockedOrAsleep)
                }),
            ]
            let teardown = Teardown { for observer in observers { observer.center.removeObserver(observer.token) } }
            continuation.onTermination = { _ in teardown.run() }
        }
    }
}
