import ApplicationServices
import Foundation
import os

/// Whether Accessibility is granted. A stream emits the current value first, then each change; the
/// value is re-read once when the system posts its Accessibility notification.
final class AccessibilityTrust27: Sendable {
    static let notificationName = Notification.Name("com.apple.accessibility.api")

    private let dispatchQueue = DispatchQueue(label: "com.michaelrigart.hulder.accessibility-trust", qos: .utility)
    private let queue = OperationQueue()

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = dispatchQueue
    }

    func values() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let last = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            let emit: @Sendable () -> Void = {
                let trusted = AXIsProcessTrusted()
                let changed = last.withLock { last -> Bool in
                    defer { last = trusted }
                    return last != trusted
                }
                if changed { continuation.yield(trusted) }
            }
            let center = DistributedNotificationCenter.default()
            let observer = center.addObserver(forName: Self.notificationName, object: nil, queue: queue) { _ in emit() }
            queue.addOperation(emit)
            let teardown = Teardown { center.removeObserver(observer) }
            continuation.onTermination = { _ in teardown.run() }
        }
    }
}
