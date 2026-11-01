import Foundation

/// Runs a cleanup closure once, from whichever thread ends a stream. It lets non-`Sendable` observer
/// tokens be released from `AsyncStream.Continuation.onTermination`.
final class Teardown: @unchecked Sendable { // reason: the closure is only taken and cleared under `lock`
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}
