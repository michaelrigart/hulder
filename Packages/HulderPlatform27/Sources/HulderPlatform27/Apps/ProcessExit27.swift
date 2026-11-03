import Darwin
import Dispatch
import os

/// When a process exits, from a process dispatch source. Nothing polls.
enum ProcessExit27 {
    private static let queue = DispatchQueue(label: "com.michaelrigart.hulder.process-exit", qos: .utility)

    /// Yields exactly once when the process exits, then finishes. The source is armed first, and right after it the
    /// process is checked: a pid that no longer exists is reported at once, without relying on the source to notice
    /// an exit that happened before it was armed. Both can report the same exit, and a once flag lets only the first
    /// through. Ending the stream cancels the source. `queue` runs the source's handler.
    static func exits(of pid: pid_t, on queue: DispatchQueue = ProcessExit27.queue) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let reported = OSAllocatedUnfairLock(initialState: false)
            let report = { @Sendable in
                let first = reported.withLock { reported -> Bool in
                    defer { reported = true }
                    return !reported
                }
                guard first else { return }
                continuation.yield()
                continuation.finish()
            }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler(handler: report)
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
            if kill(pid, 0) == -1, errno == ESRCH { report() }
        }
    }
}
