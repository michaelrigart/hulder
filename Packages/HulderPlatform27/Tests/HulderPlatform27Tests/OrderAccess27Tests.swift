import Foundation
import HulderCore
import Synchronization
import Testing
@testable import HulderPlatform27

@Test func theSuggestedLocationIsTheGroupContainer() {
    let access = OrderAccess27(storage: MemoryBookmarks().storage, home: URL(filePath: "/Users/example"))
    #expect(access.suggestedLocation.path(percentEncoded: false) == "/Users/example/Library/Group Containers/com.apple.MenuBar/")
}

private let wrongFolder = OrderStoreError.unsupportedFormat("Choose the com.apple.MenuBar folder in your Group Containers folder.")
private let unsupported = OrderStoreError.unsupportedFormat("The menu bar order has a format Hulder doesn't know.")

/// Records the security scopes started, by path, around the real call.
private final class ScopeLog: Sendable {
    enum Event: Equatable, Sendable {
        case start(String)
    }

    private let log = Mutex<[Event]>([])

    var events: [Event] { log.withLock { $0 } }

    var scope: OrderAccess27.SecurityScope {
        OrderAccess27.SecurityScope(start: { url in
            self.log.withLock { $0.append(.start(canonicalPath(url) ?? "")) }
            return url.startAccessingSecurityScopedResource()
        })
    }
}

private func openStore(_ backend: FakePositionsBackend, _ folders: OrderFolders) async throws -> OrderStore27 {
    try await OrderStore27.open(backend: backend, container: folders.container, backups: folders.backups, drawnKeys: { _ in [] })
}

@Test func grantRefusesAnotherFolder() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0])
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.home)

    await #expect(throws: wrongFolder) { try await access.grant(pickedURL: folders.preferences) }
    #expect(bookmarks.stored == nil)
    #expect(await !access.isGranted())
}

/// Writes to a copy would be confirmed while the bar never moves.
@Test func grantRefusesACopyOfTheContainerElsewhere() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0, "status:com.example.a::Item-0": 233])
    let copy = try folders.makeCopyElsewhere()
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.home)

    await #expect(throws: wrongFolder) { try await access.grant(pickedURL: copy) }
    #expect(bookmarks.stored == nil)
    #expect(await !access.isGranted())
}

@Test func aSecondGrantOfTheSameFolderKeepsItsScope() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0, "status:com.example.a::Item-0": 233])
    let scopes = ScopeLog()
    let access = OrderAccess27(storage: MemoryBookmarks().storage, home: folders.home, scope: scopes.scope)

    try await access.grant(pickedURL: folders.container)
    let first = await access.container()
    try await access.grant(pickedURL: folders.container)

    #expect(scopes.events == [.start(canonicalPath(folders.container)!)])
    #expect(await access.container() == first)
}

/// R40 at launch: a stored bookmark that resolves outside the group container grants nothing, and stays until a
/// valid grant replaces it.
@Test func aStoredBookmarkOutsideTheGroupContainerIsNotGranted() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0, "status:com.example.a::Item-0": 233])
    let elsewhere = try folders.makeCopyElsewhere()
    let stored = try elsewhere.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    let bookmarks = MemoryBookmarks(stored)
    let scopes = ScopeLog()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.home, scope: scopes.scope)

    #expect(await access.container() == nil)
    #expect(await !access.isGranted())
    #expect(scopes.events.isEmpty)
    #expect(bookmarks.stored == stored)

    try await access.grant(pickedURL: folders.container)

    #expect(scopes.events == [.start(canonicalPath(folders.container)!)])
    #expect(bookmarks.stored != stored)
    #expect(canonicalPath(await access.container()) == canonicalPath(folders.container))
}

/// The same file gives the same reason whether a grant or the store reads it.
@Test func aFileWithoutPositionsIsAnUnknownFormatEverywhere() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlistWithoutPositions()
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.home)

    await #expect(throws: unsupported) { try await access.grant(pickedURL: folders.container) }
    #expect(bookmarks.stored == nil)
    await #expect(throws: unsupported) { try await openStore(FakePositionsBackend(nil), folders) }
}

@Test func anUnreadableOrderFileIsNoAccessEverywhere() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    let access = OrderAccess27(storage: MemoryBookmarks().storage, home: folders.home)

    await #expect(throws: OrderStoreError.noAccess) { try await access.grant(pickedURL: folders.container) }
    await #expect(throws: OrderStoreError.noAccess) { try await openStore(FakePositionsBackend(nil), folders) }

    // Positions in the file that the preferences can't see are no access either.
    try folders.writePlist(["module:Clock": 0])
    await #expect(throws: OrderStoreError.noAccess) { try await openStore(FakePositionsBackend(nil), folders) }
}

@Test func aGrantLastsAcrossLaunchesThroughItsBookmark() async throws {
    let folders = try OrderFolders()
    defer { folders.remove() }
    try folders.writePlist(["module:Clock": 0, "status:com.example.a::Item-0": 233])
    let bookmarks = MemoryBookmarks()
    let access = OrderAccess27(storage: bookmarks.storage, home: folders.home)
    let grants = Mutex(0)
    access.onGrant { grants.withLock { $0 += 1 } }

    try await access.grant(pickedURL: folders.container)

    #expect(grants.withLock { $0 } == 1)
    #expect(await access.isGranted())
    #expect(canonicalPath(await access.container()) == canonicalPath(folders.container))
    let relaunched = OrderAccess27(storage: bookmarks.storage, home: folders.home)
    #expect(canonicalPath(await relaunched.container()) == canonicalPath(folders.container))
}

@Test func withoutABookmarkNothingIsGranted() async {
    let access = OrderAccess27(storage: MemoryBookmarks().storage, home: URL(filePath: "/Users/example"))
    #expect(await !access.isGranted())
    #expect(await access.container() == nil)
}
