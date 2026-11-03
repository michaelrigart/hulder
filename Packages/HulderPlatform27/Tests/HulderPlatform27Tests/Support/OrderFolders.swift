import Foundation
import HulderCore
import Synchronization
@testable import HulderPlatform27

/// A temporary home holding the group container where macOS keeps it, with a backups folder beside it.
struct OrderFolders {
    let root: URL

    var home: URL { root }
    var container: URL { home.appending(path: "Library/Group Containers/com.apple.MenuBar") }
    var preferences: URL { container.appending(path: "Library/Preferences") }
    var plist: URL { preferences.appending(path: "com.apple.MenuBar.plist") }
    var backups: URL { root.appending(path: "OrderBackups") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "HulderOrderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
    }

    static func plistData(_ positions: [String: Double]) throws -> Data {
        try plistData(raw: ["TrailingItemPreferredPositions": positions])
    }

    static func plistData(raw: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
    }

    func writePlist(_ positions: [String: Double], to url: URL? = nil) throws {
        try Self.plistData(positions).write(to: url ?? plist)
    }

    /// An order file in a format Hulder doesn't know: a property list without the positions.
    func writePlistWithoutPositions() throws {
        try Self.plistData(raw: ["Other": 1]).write(to: plist)
    }

    /// A folder named like the container, elsewhere in the temporary home, holding a copy of the order file.
    func makeCopyElsewhere() throws -> URL {
        let copy = root.appending(path: "Elsewhere/com.apple.MenuBar")
        let preferences = copy.appending(path: "Library/Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: plist, to: preferences.appending(path: "com.apple.MenuBar.plist"))
        return copy
    }

    func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false)).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Bookmark storage in memory, so tests never touch the app's defaults.
final class MemoryBookmarks: Sendable {
    private let data: Mutex<Data?>

    init(_ data: Data? = nil) {
        self.data = Mutex(data)
    }

    var stored: Data? { data.withLock { $0 } }

    var storage: OrderAccess27.BookmarkStorage {
        OrderAccess27.BookmarkStorage(load: { self.data.withLock { $0 } }, save: { new in self.data.withLock { $0 = new } })
    }
}

/// The resolved, standardized path, for comparing folders whatever symlinks led to them.
func canonicalPath(_ url: URL?) -> String? {
    url.map {
        let path = $0.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
