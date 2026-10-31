#if DEBUG
import AppKit

/// The container-aware preferences functions CoreFoundation exports. They are resolved with
/// `dlsym` and never linked, so a missing one is reported instead of failing the launch.
struct ProbeCFPreferences {
    static let applicationID = "com.apple.MenuBar"

    private typealias CopyFunction = @convention(c) (CFString, CFString, CFString) -> UnsafeRawPointer?
    private typealias SetFunction = @convention(c) (CFString, UnsafeRawPointer?, CFString, CFString) -> Void
    private typealias SynchronizeFunction = @convention(c) (CFString, CFString) -> UInt8

    private let copyFunction: CopyFunction
    private let setFunction: SetFunction
    private let synchronizeFunction: SynchronizeFunction
    let containerPath: String

    init?(containerPath: String, label: String) {
        let image = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY) ?? UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func resolve(_ name: String) -> UnsafeMutableRawPointer? {
            let symbol = dlsym(image, name)
            note("\(label): \(name) \(symbol == nil ? "missing" : "present")")
            return symbol
        }
        let copy = resolve("_CFPreferencesCopyAppValueWithContainer")
        let set = resolve("_CFPreferencesSetAppValueWithContainer")
        let synchronize = resolve("_CFPreferencesAppSynchronizeWithContainer")
        guard let copy, let set, let synchronize else { return nil }
        copyFunction = unsafeBitCast(copy, to: CopyFunction.self)
        setFunction = unsafeBitCast(set, to: SetFunction.self)
        synchronizeFunction = unsafeBitCast(synchronize, to: SynchronizeFunction.self)
        self.containerPath = containerPath
    }

    func copyValue(_ key: String) -> Any? {
        guard let raw = copyFunction(key as CFString, Self.applicationID as CFString, containerPath as CFString) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
    }

    func setValue(_ key: String, _ value: NSDictionary) {
        let raw = Unmanaged.passUnretained(value).toOpaque()
        setFunction(key as CFString, UnsafeRawPointer(raw), Self.applicationID as CFString, containerPath as CFString)
    }

    func synchronize() -> Bool {
        synchronizeFunction(Self.applicationID as CFString, containerPath as CFString) != 0
    }
}

/// `TrailingItemPreferredPositions`: item key to points from the trailing edge, larger is further left.
typealias ProbePositions = [String: NSNumber]

/// Shared pieces of the `order-*` subcommands that read and write the Menu Bar preferences.
@MainActor
enum ProbeOrder {
    static let positionsKey = "TrailingItemPreferredPositions"
    static let backupsToKeep = 10

    struct Context {
        let root: URL
        let preferences: ProbeCFPreferences

        var plistURL: URL { root.appendingPathComponent("Library/Preferences/com.apple.MenuBar.plist") }
        var preferencesDirectory: URL { plistURL.deletingLastPathComponent() }
    }

    /// Runs `body` with the picked folder open and the CF functions resolved; logs and stops otherwise.
    static func withContext(label: String, _ body: @MainActor (Context) async -> Void) async {
        await ProbeOrderDump.withBookmarkedFolder(label: label) { root in
            note("\(label): container \(root.path)")
            guard let preferences = ProbeCFPreferences(containerPath: root.path, label: label) else { return }
            await body(Context(root: root, preferences: preferences))
        }
    }

    // MARK: Reading

    static func positions(from value: Any?) -> ProbePositions? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary.compactMapValues { $0 as? NSNumber }
    }

    static func readCF(_ context: Context) -> ProbePositions? {
        positions(from: context.preferences.copyValue(positionsKey))
    }

    static func readFile(at url: URL) -> ProbePositions? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return positions(from: plist[positionsKey])
    }

    static func readFile(_ context: Context) -> ProbePositions? {
        readFile(at: context.plistURL)
    }

    // MARK: Writing

    /// Writes the whole dictionary, then synchronizes. Returns the Bool and the elapsed milliseconds.
    static func write(_ positions: ProbePositions, _ context: Context) -> (synchronized: Bool, milliseconds: Int) {
        let start = ContinuousClock.now
        context.preferences.setValue(positionsKey, positions as NSDictionary)
        let synchronized = context.preferences.synchronize()
        return (synchronized, ProbeRunner.milliseconds(ContinuousClock.now - start))
    }

    // MARK: Logging

    static func format(_ value: NSNumber?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    static func diff(old: ProbePositions, new: ProbePositions, excluding excluded: String? = nil) -> [String] {
        var changes: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where key != excluded {
            switch (old[key], new[key]) {
            case let (was?, now?) where was.doubleValue != now.doubleValue:
                changes.append("changed \(key) \(format(was)) -> \(format(now))")
            case let (nil, now?):
                changes.append("added \(key) \(format(now))")
            case let (was?, nil):
                changes.append("removed \(key) \(format(was))")
            default:
                break
            }
        }
        return changes
    }

    static func logDiff(_ prefix: String, old: ProbePositions?, new: ProbePositions?) {
        guard let new else {
            note("\(prefix): unreadable")
            return
        }
        guard let old else {
            note("\(prefix): \(new.count) keys (no previous reading)")
            return
        }
        let changes = diff(old: old, new: new)
        if changes.isEmpty {
            note("\(prefix): no change")
        } else {
            for change in changes { note("\(prefix): \(change)") }
        }
    }

    static func equal(_ lhs: ProbePositions, _ rhs: ProbePositions) -> Bool {
        diff(old: lhs, new: rhs).isEmpty
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Backups

    static var backupsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.michaelrigart.hulder/OrderBackups")
    }

    static func backups() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies the plist into the backups folder and prunes to the newest `backupsToKeep`.
    /// Returns the new backup's URL, or nil after logging why not.
    static func makeBackup(of context: Context) -> URL? {
        let destination = backupsDirectory.appendingPathComponent("\(timestamp()).plist")
        do {
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: context.plistURL, to: destination)
        } catch {
            note("backup failed code=\((error as NSError).code) domain=\((error as NSError).domain)")
            PlatformLog.probe.notice("backup failure detail: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        note("backup written: \(destination.lastPathComponent)")
        let all = backups()
        for stale in all.dropLast(backupsToKeep) {
            do {
                try FileManager.default.removeItem(at: stale)
                note("backup pruned: \(stale.lastPathComponent)")
            } catch {
                note("backup prune failed: \(stale.lastPathComponent) code=\((error as NSError).code)")
            }
        }
        return destination
    }
}

/// The state of one `order-watch`, mutated only on the main queue the file-system source runs on.
@MainActor
private final class OrderWatchState {
    let context: ProbeOrder.Context
    var file: ProbePositions?
    var cf: ProbePositions?
    var events = 0

    init(context: ProbeOrder.Context) {
        self.context = context
        file = ProbeOrder.readFile(context)
        cf = ProbeOrder.readCF(context)
    }

    func logInitial() {
        note("order-watch: initial file keys=\(file.map { "\($0.count)" } ?? "unreadable") cf keys=\(cf.map { "\($0.count)" } ?? "unreadable")")
        if let file, let cf {
            let changes = ProbeOrder.diff(old: file, new: cf)
            note("order-watch: file and cf \(changes.isEmpty ? "agree" : "differ")")
            for change in changes { note("order-watch: file -> cf \(change)") }
        }
    }

    func handle(_ flags: DispatchSource.FileSystemEvent) {
        events += 1
        note("order-watch: event \(events) at \(ProbeOrder.timestamp()) flags=\(flags.rawValue)")
        let newFile = ProbeOrder.readFile(context)
        ProbeOrder.logDiff("order-watch: file", old: file, new: newFile)
        file = newFile ?? file
        let newCF = ProbeOrder.readCF(context)
        ProbeOrder.logDiff("order-watch: cf", old: cf, new: newCF)
        cf = newCF ?? cf
    }
}

extension ProbeRunner {
    // MARK: order-watch

    func orderWatch() async {
        await ProbeOrder.withContext(label: "order-watch") { context in
            let state = OrderWatchState(context: context)
            state.logInitial()

            let directory = context.preferencesDirectory
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                note("order-watch: could not open \(directory.path) errno=\(errno)")
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: .main
            )
            source.setEventHandler { [unowned source] in
                let flags = source.data
                MainActor.assumeIsolated { state.handle(flags) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()

            note("order-watch: watching \(directory.path) for \(Self.watchDuration)")
            do { try await clock.sleep(for: Self.watchDuration) } catch { note("order-watch: wait cancelled") }
            source.cancel()
            note("order-watch: finished after \(state.events) events")
        }
    }

    // MARK: order-move

    func orderMove(_ key: String, anchor: String) async {
        await ProbeOrder.withContext(label: "order-move") { context in
            guard ProbeOrder.makeBackup(of: context) != nil else { return }

            guard let cf = ProbeOrder.readCF(context) else {
                note("order-move: cf read returned no dictionary")
                return
            }
            let file = ProbeOrder.readFile(context)
            if let file {
                let changes = ProbeOrder.diff(old: file, new: cf)
                note("order-move: cf dictionary \(changes.isEmpty ? "equals" : "differs from") the file's (cf keys=\(cf.count) file keys=\(file.count))")
                for change in changes { note("order-move: file -> cf \(change)") }
            } else {
                note("order-move: file dictionary unreadable")
            }
            guard let current = cf[key], let anchorValue = cf[anchor]?.doubleValue else {
                note("order-move: missing key: \(key)=\(cf[key] == nil ? "missing" : "present") \(anchor)=\(cf[anchor] == nil ? "missing" : "present")")
                return
            }

            let above = cf.filter { $0.key != key && $0.value.doubleValue > anchorValue }.map(\.value.doubleValue).min()
            let target = above.map { (anchorValue + $0) / 2 } ?? anchorValue + 20
            note("order-move: \(key) \(ProbeOrder.format(current)) -> \(target) (anchor \(anchor)=\(anchorValue), next above anchor=\(above.map { "\($0)" } ?? "none"))")

            var updated = cf
            updated[key] = NSNumber(value: target)
            let result = ProbeOrder.write(updated, context)
            note("order-move: write synchronized=\(result.synchronized) elapsedMs=\(result.milliseconds)")

            let afterCF = ProbeOrder.readCF(context)
            let afterFile = ProbeOrder.readFile(context)
            note("order-move: after write cf \(key)=\(ProbeOrder.format(afterCF?[key])) file \(key)=\(ProbeOrder.format(afterFile?[key]))")

            await panel.wait("Did the icon move next to the anchor? Did anything flicker or reflow? Note the answer, then click Continue.")
        }
    }

    // MARK: order-restore

    func orderRestore() async {
        await ProbeOrder.withContext(label: "order-restore") { context in
            guard let backup = ProbeOrder.backups().last else {
                note("order-restore: no backup in \(ProbeOrder.backupsDirectory.path)")
                return
            }
            note("order-restore: using backup \(backup.lastPathComponent)")
            guard let saved = ProbeOrder.readFile(at: backup) else {
                note("order-restore: backup has no \(ProbeOrder.positionsKey)")
                return
            }
            let before = ProbeOrder.readCF(context) ?? [:]
            let result = ProbeOrder.write(saved, context)
            note("order-restore: write synchronized=\(result.synchronized) elapsedMs=\(result.milliseconds)")
            let after = ProbeOrder.readCF(context) ?? [:]
            let changes = ProbeOrder.diff(old: before, new: saved)
            note("order-restore: \(changes.count) keys changed by the write")
            for change in changes { note("order-restore: \(change)") }
            let residual = ProbeOrder.diff(old: saved, new: after)
            note("order-restore: cf re-read \(residual.isEmpty ? "equals the backup" : "differs from the backup")")
            for change in residual { note("order-restore: backup -> cf \(change)") }

            await panel.wait("Is the original order back? Click Continue.")
        }
    }

    // MARK: order-stress

    func orderStress(_ key: String) async {
        await ProbeOrder.withContext(label: "order-stress") { context in
            guard let original = ProbeOrder.readCF(context), let originalValue = original[key] else {
                note("order-stress: \(key) is not in the cf dictionary")
                return
            }
            note("order-stress: \(key) starts at \(ProbeOrder.format(originalValue)), \(original.count) keys")
            await panel.wait("Click Continue, then ⌘-drag any icon other than \(key) to a new place within 20 seconds and leave it there.")

            let before = ProbeOrder.readCF(context) ?? original
            let base = (before[key] ?? originalValue).doubleValue
            let deadline = ContinuousClock.now + .seconds(20)
            var writes = 0
            var unsynchronized = 0
            while ContinuousClock.now < deadline {
                if var current = ProbeOrder.readCF(context) {
                    current[key] = NSNumber(value: writes.isMultiple(of: 2) ? base + 0.001 : base - 0.001)
                    if !ProbeOrder.write(current, context).synchronized { unsynchronized += 1 }
                    writes += 1
                } else {
                    note("order-stress: cf read returned no dictionary")
                }
                try? await clock.sleep(for: .milliseconds(50))
            }

            var last = ProbeOrder.readCF(context) ?? before
            last[key] = before[key] ?? originalValue
            let final = ProbeOrder.write(last, context)
            note("order-stress: \(writes) writes, \(unsynchronized) unsynchronized; final write of \(key)=\(ProbeOrder.format(last[key])) synchronized=\(final.synchronized)")

            let afterCF = ProbeOrder.readCF(context)
            let afterFile = ProbeOrder.readFile(context)
            for (label, snapshot) in [("cf", afterCF), ("file", afterFile)] {
                guard let snapshot else {
                    note("order-stress: \(label) final read unreadable")
                    continue
                }
                let changes = ProbeOrder.diff(old: before, new: snapshot, excluding: key)
                note("order-stress: \(label) vs before the loop, excluding \(key): \(changes.isEmpty ? "no difference" : "\(changes.count) differences"); \(key)=\(ProbeOrder.format(snapshot[key]))")
                for change in changes { note("order-stress: \(label) \(change)") }
            }

            await panel.wait("Is the icon you dragged still where you left it? Click Continue.")
        }
    }
}
#endif
