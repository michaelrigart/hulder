import Dispatch
import os

/// Runs blocking Accessibility (and private-framework) calls on dedicated serial queues,
/// off the main actor and the cooperative pool. Work goes to the least busy queue.
final class AXQueue: Sendable {
    /// The per-element messaging timeout callers should pass to `ExtrasMenuBarReader`.
    let messagingTimeout: Float

    private let queues: [DispatchQueue]
    private let pending: OSAllocatedUnfairLock<[Int]>

    init(width: Int = 4, messagingTimeout: Float = 0.25) {
        let width = max(1, width)
        self.messagingTimeout = messagingTimeout
        queues = (0..<width).map { DispatchQueue(label: "com.michaelrigart.hulder.ax.\($0)", qos: .userInitiated) }
        pending = OSAllocatedUnfairLock(initialState: Array(repeating: 0, count: width))
    }

    func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        let index = pending.withLock { counts -> Int in
            let index = counts.indices.min { counts[$0] < counts[$1] } ?? 0
            counts[index] += 1
            return index
        }
        return await withCheckedContinuation { continuation in
            queues[index].async {
                let result = body()
                self.pending.withLock { $0[index] -= 1 }
                continuation.resume(returning: result)
            }
        }
    }
}
