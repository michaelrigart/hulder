import AppKit
import HulderCore

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
    /// The last yielded set; only touched on the stream's serial queue.
    private final class Last: @unchecked Sendable { // reason: confined to the stream's serial queue
        var apps: Set<AppID>?
    }

    func values() -> AsyncStream<Set<AppID>> {
        AsyncStream { continuation in
            // The KVO callbacks arrive on whichever thread changed the list (`.initial` on this one). They only
            // enqueue; the read happens on one serial queue, no lock is held across AppKit, and each read comes
            // after the change that triggered it, so the last one yielded is the newest.
            let queue = DispatchQueue(label: "com.michaelrigart.hulder.running-apps", qos: .utility)
            let last = Last()
            let observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { _, _ in
                queue.async {
                    let apps = NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.activationPolicy.rawValue) }
                    let current = RunningAppsFilter.appIDs(apps)
                    guard last.apps != current else { return }
                    last.apps = current
                    continuation.yield(current)
                }
            }
            let teardown = Teardown { observation.invalidate() }
            continuation.onTermination = { _ in teardown.run() }
        }
    }
}
