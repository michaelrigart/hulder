import AppKit
import HulderCore
import HulderPlatform27
import Synchronization

/// Starts a new copy of Hulder and quits this one. The helper it starts (`RelaunchHelper`) stays until a
/// new copy is confirmed running: it waits for this process to exit and for LaunchServices to drop it,
/// opens Hulder, and opens it again when no new copy appears, so a relaunch never leaves two copies or none.
enum Relaunch {
    private static let started = Mutex(false)

    /// Returns false, and leaves Hulder running, when the new copy could not be scheduled. The quit is
    /// scheduled on the run loop, not made in the caller's main-queue job, so the shutdown can run
    /// while AppKit waits for it. A process starts one helper at most: a later call returns true
    /// without starting another.
    @discardableResult
    static func perform() -> Bool {
        guard started.withLock({ !$0 }) else { return true }
        let process = Process()
        let command = RelaunchHelper().invocation(
            oldPID: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundleURL.path,
            bundleID: Bundle.main.bundleIdentifier ?? HulderCore.bundleID)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.notice("Could not start the relaunch; Hulder keeps running")
            return false
        }
        started.withLock { $0 = true }
        Log.app.notice("Relaunching Hulder")
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        return true
    }
}
