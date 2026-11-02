import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

/// Bookmark storage in memory, so tests never touch the app's defaults.
private final class MemoryBookmarks: Sendable {
    private let data = Mutex<Data?>(nil)

    var stored: Data? { data.withLock { $0 } }

    var storage: OrderAccess27.BookmarkStorage {
        OrderAccess27.BookmarkStorage(load: { self.data.withLock { $0 } }, save: { new in self.data.withLock { $0 = new } })
    }
}

private func canonicalPath(_ url: URL?) -> String? {
    url.map { $0.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/") }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

@Test func theSuggestedLocationIsTheGroupContainer() {
    let access = OrderAccess27(storage: MemoryBookmarks().storage, home: URL(filePath: "/Users/example"))
    #expect(access.suggestedLocation.path(percentEncoded: false) == "/Users/example/Library/Group Containers/com.apple.MenuBar/")
}

@Test func grantRefusesAnotherFolder() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0])
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.root)

    await #expect(throws: OrderStoreError.noAccess) { try await access.grant(pickedURL: folders.root) }
    #expect(bookmarks.stored == nil)
    #expect(await !access.isGranted())
}

@Test func grantRefusesAnOrderFileItCannotDecode() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .binary, options: 0).write(to: folders.plist)
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.root)

    await #expect(throws: OrderStoreError.unsupportedFormat("The menu bar order has a format Hulder doesn't know.")) {
        try await access.grant(pickedURL: folders.container)
    }
    #expect(bookmarks.stored == nil)
    #expect(await !access.isGranted())
}

@Test func aGrantLastsAcrossLaunchesThroughItsBookmark() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0, "status:com.example.a::Item-0": 233])
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.root)
    let grants = Mutex(0)
    access.onGrant { grants.withLock { $0 += 1 } }

    try await access.grant(pickedURL: folders.container)

    #expect(grants.withLock { $0 } == 1)
    #expect(await access.isGranted())
    #expect(canonicalPath(await access.container()) == canonicalPath(folders.container))
    let relaunched = OrderAccess27(storage: bookmarks.storage, home: folders.root)
    #expect(canonicalPath(await relaunched.container()) == canonicalPath(folders.container))
}

@Test func withoutABookmarkNothingIsGranted() async {
    let access = OrderAccess27(storage: MemoryBookmarks().storage, home: URL(filePath: "/Users/example"))
    #expect(await !access.isGranted())
    #expect(await access.container() == nil)
}
