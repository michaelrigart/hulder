import Foundation

/// The per-process key-value observations behind `RunningApps27.finishedLaunching`. Each observed object is held
/// next to its token and the token is invalidated before the object is released: AppKit drops an app's
/// `NSRunningApplication` as soon as the process is gone, and a Swift observation torn down while its observed
/// object deallocates crashes. Only touched on one serial queue.
final class LaunchWatches<Object: NSObject>: @unchecked Sendable { // reason: confined to the stream's serial queue
    private struct Entry {
        let object: Object
        let token: NSKeyValueObservation
    }

    private let pid: (Object) -> pid_t
    private let watch: (Object) -> NSKeyValueObservation
    private var entries: [pid_t: Entry] = [:]
    private var stopped = false

    init(pid: @escaping (Object) -> pid_t, watch: @escaping (Object) -> NSKeyValueObservation) {
        self.pid = pid
        self.watch = watch
    }

    deinit { removeAll() }

    /// Drops the watch of every process missing from `apps`, then watches each app that `needsWatch` accepts and
    /// that isn't watched yet. Does nothing once `removeAll` has run: an update queued behind the teardown must not
    /// start new watches.
    func update(_ apps: [Object], needsWatch: (Object) -> Bool) {
        guard !stopped else { return }
        let live = Set(apps.map(pid))
        let gone = entries.keys.filter { !live.contains($0) }
        for key in gone { remove(key) }
        for app in apps where needsWatch(app) && entries[pid(app)] == nil {
            entries[pid(app)] = Entry(object: app, token: watch(app))
        }
    }

    func removeAll() {
        stopped = true
        for key in Array(entries.keys) { remove(key) }
    }

    private func remove(_ key: pid_t) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        withExtendedLifetime(entry.object) { entry.token.invalidate() }
    }
}
