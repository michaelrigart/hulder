import Dispatch
import Foundation

/// Runs an executable and reads its exit status as a yes or no: 0 is true, 1 is false. A child that
/// fails to start, ends any other way, or does not exit within `timeout` seconds answers nil. A child
/// still running at the timeout is terminated, and killed when it has not exited 0.5 s later; the
/// answer then waits at most 0.5 s more for the exit, so the wait always ends. It waits on a
/// background queue, never the caller's thread.
struct ChildExitStatus: Sendable {
    let executable: URL
    let arguments: [String]
    let timeout: TimeInterval
    let kill: @Sendable (pid_t) -> Void

    private static let graceAfterTerminate: TimeInterval = 0.5
    private static let graceAfterKill: TimeInterval = 0.5

    init(executable: URL, arguments: [String], timeout: TimeInterval,
         kill: @escaping @Sendable (pid_t) -> Void = { Darwin.kill($0, SIGKILL) }) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.kill = kill
    }

    func run() async -> Bool? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runAndWait())
            }
        }
    }

    private func runAndWait() -> Bool? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + Self.graceAfterTerminate) == .timedOut {
                kill(process.processIdentifier)
                _ = exited.wait(timeout: .now() + Self.graceAfterKill)
            }
            return nil
        }
        guard process.terminationReason == .exit else { return nil }
        return switch process.terminationStatus {
        case 0: true
        case 1: false
        default: nil
        }
    }
}
