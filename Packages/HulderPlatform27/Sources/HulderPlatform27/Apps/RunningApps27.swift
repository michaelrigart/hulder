import AppKit
import HulderCore

enum RunningAppsFilter {
    /// Every app with a bundle identifier counts, whatever its activation policy: agent and helper
    /// apps own menu bar items too.
    static func appIDs(_ apps: [(bundleID: String?, policy: Int)]) -> Set<AppID> {
        Set(apps.compactMap { $0.bundleID.map(AppID.init) })
    }
}

/// The running apps, from key-value observing of `NSWorkspace.runningApplications`. The launch notification is
/// not delivered for agent apps.
final class RunningApps27: Sendable {
    /// The last yielded value; only touched on the stream's serial queue.
    private final class Last<Value: Sendable & Equatable>: @unchecked Sendable { // reason: confined to the stream's serial queue
        var value: Value?
    }

    func values() -> AsyncStream<Set<AppID>> {
        observe { apps in RunningAppsFilter.appIDs(apps.map { ($0.bundleIdentifier, $0.activationPolicy.rawValue) }) }
    }

    /// The processes menu tracking watches: every app whose activation policy isn't prohibited.
    func trackablePIDs() -> AsyncStream<Set<pid_t>> {
        observe { apps in Set(apps.filter { $0.activationPolicy != .prohibited }.map(\.processIdentifier)) }
    }

    /// The bundle identifier of each trackable process that has one.
    func trackableIdentities() -> AsyncStream<[pid_t: String]> {
        observe { apps in
            Dictionary(
                apps.filter { $0.activationPolicy != .prohibited }.compactMap { app in
                    app.bundleIdentifier.map { (app.processIdentifier, $0) }
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// The pid of each trackable app once it has finished launching, which is when its Accessibility server
    /// exists. Key-value observing of `isFinishedLaunching`, only for apps still launching.
    func finishedLaunching() -> AsyncStream<pid_t> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.michaelrigart.hulder.launching-apps", qos: .utility)
            let watched = Watched()
            let observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { _, _ in
                queue.async {
                    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
                    let live = Set(apps.map(\.processIdentifier))
                    for pid in watched.tokens.keys where !live.contains(pid) {
                        watched.tokens.removeValue(forKey: pid)?.invalidate()
                    }
                    for app in apps where !app.isFinishedLaunching && watched.tokens[app.processIdentifier] == nil {
                        let pid = app.processIdentifier
                        watched.tokens[pid] = app.observe(\.isFinishedLaunching, options: [.initial, .new]) { app, _ in
                            if app.isFinishedLaunching { continuation.yield(pid) }
                        }
                    }
                }
            }
            let teardown = Teardown {
                observation.invalidate()
                queue.async { watched.tokens.values.forEach { $0.invalidate() }; watched.tokens = [:] }
            }
            continuation.onTermination = { _ in teardown.run() }
        }
    }

    /// The per-app observations of `finishedLaunching`; only touched on its serial queue.
    private final class Watched: @unchecked Sendable { // reason: confined to the stream's serial queue
        var tokens: [pid_t: NSKeyValueObservation] = [:]
    }

    private func observe<Value: Sendable & Equatable>(_ read: @escaping @Sendable ([NSRunningApplication]) -> Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            // The KVO callbacks arrive on whichever thread changed the list (`.initial` on this one). They only
            // enqueue; the read happens on one serial queue, no lock is held across AppKit, and each read comes
            // after the change that triggered it, so the last one yielded is the newest.
            let queue = DispatchQueue(label: "com.michaelrigart.hulder.running-apps", qos: .utility)
            let last = Last<Value>()
            let observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { _, _ in
                queue.async {
                    let current = read(NSWorkspace.shared.runningApplications)
                    guard last.value != current else { return }
                    last.value = current
                    continuation.yield(current)
                }
            }
            let teardown = Teardown { observation.invalidate() }
            continuation.onTermination = { _ in teardown.run() }
        }
    }
}
