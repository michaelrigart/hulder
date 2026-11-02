import Darwin
import Dispatch

/// When a process exits, from a process dispatch source. Nothing polls.
enum ProcessExit27 {
    private static let queue = DispatchQueue(label: "com.michaelrigart.hulder.process-exit", qos: .utility)

    /// Yields once when the process exits, then finishes. A process that is already gone yields at once: the source
    /// can only report an exit that happens after it is armed, so right after arming it the process is checked, and a
    /// pid that no longer exists is reported without waiting. Ending the stream cancels the source.
    static func exits(of pid: pid_t) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
            if kill(pid, 0) == -1, errno == ESRCH {
                continuation.yield()
                continuation.finish()
            }
        }
    }
}
