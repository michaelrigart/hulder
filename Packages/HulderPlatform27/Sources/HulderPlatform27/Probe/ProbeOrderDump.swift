#if DEBUG
import AppKit

/// `order-dump`: what is under `~/Library/Group Containers/com.apple.MenuBar`, and what the
/// property lists in it contain.
enum ProbeOrderDump {
    private static let arrayEntryLimit = 200
    private static let depthLimit = 8

    static let bookmarkKey = "HulderProbeOrderBookmark"

    private static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar")
    }

    /// Dumps the folder chosen by `order-pick` through its security-scoped bookmark, or the
    /// default folder when there is no bookmark.
    @MainActor
    static func run() async {
        guard UserDefaults.standard.data(forKey: bookmarkKey) != nil else {
            note("order-dump: no bookmark stored, using the default folder")
            run(root: defaultRoot)
            return
        }
        await withBookmarkedFolder(label: "order-dump") { run(root: $0) }
    }

    /// Resolves the folder stored by `order-pick` and keeps security-scoped access open while
    /// `body` runs. Returns nil, after logging why, when there is no usable bookmark.
    @MainActor
    @discardableResult
    static func withBookmarkedFolder<T>(label: String, _ body: @MainActor (URL) async -> T) async -> T? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            note("\(label): no bookmark stored; run order-pick first")
            return nil
        }
        note("\(label): using the stored bookmark (\(bookmark.count) bytes)")
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            note("\(label): bookmark resolution failed code=\((error as NSError).code)")
            return nil
        }
        note("\(label): bookmark resolved isStale=\(isStale)")
        let started = url.startAccessingSecurityScopedResource()
        note("\(label): startAccessingSecurityScopedResource=\(started)")
        defer { url.stopAccessingSecurityScopedResource() }
        return await body(url)
    }

    /// Shows an open panel on the group container, then dumps the choice and stores a
    /// security-scoped bookmark for it.
    @MainActor
    static func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultRoot.deletingLastPathComponent()
        panel.message = "Select the com.apple.MenuBar folder, then click Open."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else {
            note("order-pick: cancelled")
            return
        }
        note("order-pick: chose \(relativeToHome(url))")
        run(root: url)

        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            note("order-pick: bookmark created and stored (\(bookmark.count) bytes)")
        } catch {
            note("order-pick: bookmark creation failed code=\((error as NSError).code)")
        }
    }

    private static func relativeToHome(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    static func run(root: URL) {
        note("order-dump root: \(root.path)")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        note("root exists=\(exists) isDirectory=\(isDirectory.boolValue) readable=\(FileManager.default.isReadableFile(atPath: root.path))")

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: { url, error in
                let code = (error as NSError).code
                note("enumeration error at \(relative(url, to: root)) code=\(code)")
                PlatformLog.probe.notice("enumeration error detail: \(error.localizedDescription, privacy: .private)")
                return true
            }
        )
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            count += 1
            describe(url, root: root)
        }
        note("order-dump done: \(count) entries")
    }

    private static func describe(_ url: URL, root: URL) {
        let path = relative(url, to: root)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let accessFlag = FileManager.default.isReadableFile(atPath: url.path)
        let preferences = url.path.contains("/Library/Preferences/")
        if isDirectory {
            note("dir  \(path) isReadableFile=\(accessFlag)")
            return
        }

        let data: Data?
        var readCode = 0
        do { data = try Data(contentsOf: url) } catch {
            data = nil
            readCode = (error as NSError).code
            PlatformLog.probe.notice("read error detail: \(error.localizedDescription, privacy: .private)")
        }
        note("file \(path) size=\(values?.fileSize ?? -1) isReadableFile=\(accessFlag) readSucceeded=\(data != nil) readErrorCode=\(readCode) inPreferencesDomain=\(preferences)")
        guard let data else { return }

        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            note("  \(path) is a property list")
            dump(plist, label: "plist", depth: 0)
        } else if let json = try? JSONSerialization.jsonObject(with: data) {
            note("  \(path) is JSON")
            dump(json, label: "json", depth: 0)
        } else {
            note("  \(path) is neither a property list nor JSON; first bytes: \(hex(data.prefix(48)))")
        }
    }

    private static func dump(_ value: Any, label: String, depth: Int) {
        let indent = String(repeating: "  ", count: depth + 2)
        switch value {
        case let dictionary as [String: Any]:
            note("\(indent)\(label): dictionary(\(dictionary.count) keys)")
            guard depth < depthLimit else { return }
            for key in dictionary.keys.sorted() { dump(dictionary[key]!, label: key, depth: depth + 1) }
        case let array as [Any]:
            note("\(indent)\(label): array(\(array.count) entries)")
            guard depth < depthLimit else { return }
            for (index, element) in array.prefix(arrayEntryLimit).enumerated() {
                dump(element, label: "[\(index)]", depth: depth + 1)
            }
            if array.count > arrayEntryLimit { note("\(indent)  ... \(array.count - arrayEntryLimit) more entries not shown") }
        case let data as Data:
            note("\(indent)\(label): data(\(data.count) bytes) \(hex(data.prefix(32)))")
        case let date as Date:
            note("\(indent)\(label): date \(date)")
        case let string as String:
            note("\(indent)\(label): string \"\(string)\"")
        case let number as NSNumber:
            let kind = CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
            note("\(indent)\(label): \(kind) \(number)")
        default:
            note("\(indent)\(label): \(type(of: value)) \(value)")
        }
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.path
        return path.hasPrefix(root.path) ? "." + path.dropFirst(root.path.count) : path
    }
}
#endif
