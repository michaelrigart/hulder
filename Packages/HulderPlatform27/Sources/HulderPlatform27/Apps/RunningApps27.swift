import AppKit
import HulderCore
import os

enum RunningAppsFilter {
    /// Every app with a bundle identifier counts, whatever its activation policy: agent and helper
    /// apps own menu bar items too.
    static func appIDs(_ apps: [(bundleID: String?, policy: Int)]) -> Set<AppID> {
        Set(apps.compactMap { $0.bundleID.map(AppID.init) })
    }
}

/// The set of running apps, from key-value observing of `NSWorkspace.runningApplications`. The launch
/// notification is not delivered for agent apps.
final class RunningApps27: Sendable {
    func values() -> AsyncStream<Set<AppID>> {
        AsyncStream { continuation in
            let last = OSAllocatedUnfairLock<Set<AppID>?>(initialState: nil)
            // `.initial` runs on this thread and `.new` on whichever thread changes the list. The snapshot is
            // taken inside the lock that compares and yields, so a stale set is never yielded after a newer one.
            let observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { _, _ in
                last.withLock { last in
                    let apps = NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.activationPolicy.rawValue) }
                    let current = RunningAppsFilter.appIDs(apps)
                    guard last != current else { return }
                    last = current
                    continuation.yield(current)
                }
            }
            let teardown = Teardown { observation.invalidate() }
            continuation.onTermination = { _ in teardown.run() }
        }
    }
}
