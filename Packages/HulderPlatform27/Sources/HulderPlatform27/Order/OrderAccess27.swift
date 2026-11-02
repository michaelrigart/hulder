import Foundation
import HulderCore
import Synchronization

/// Access to the Menu Bar group container, which macOS protects. The user picks the folder once in an open
/// panel, and a security-scoped bookmark keeps that access across launches. The scope, once started, stays
/// started while Hulder runs. Bookmark and file work runs on one serial queue.
final class OrderAccess27: OrderAccess {
    static let bookmarkKey = "OrderContainerBookmark"
    static let folderName = "com.apple.MenuBar"

    /// Where the bookmark is kept: the app's defaults, or memory in tests.
    struct BookmarkStorage: Sendable {
        var load: @Sendable () -> Data?
        var save: @Sendable (Data) -> Void

        static let standard = BookmarkStorage(
            load: { UserDefaults.standard.data(forKey: bookmarkKey) },
            save: { UserDefaults.standard.set($0, forKey: bookmarkKey) }
        )
    }

    private struct State {
        /// Whether the stored bookmark has been resolved this run.
        var resolved = false
        var container: URL?
        var onGrant: (@Sendable () async -> Void)?
    }

    let suggestedLocation: URL
    private let storage: BookmarkStorage
    private let queue = DispatchQueue(label: "com.michaelrigart.hulder.order-access", qos: .userInitiated)
    private let state = Mutex(State())

    init(storage: BookmarkStorage = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.storage = storage
        suggestedLocation = home.appending(path: "Library/Group Containers/\(Self.folderName)", directoryHint: .isDirectory)
    }

    func isGranted() async -> Bool {
        await container() != nil
    }

    /// The granted container, with its security scope started, or nil. The stored bookmark is resolved once a run.
    func container() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.resolve()) }
        }
    }

    /// Accepts only a folder named `com.apple.MenuBar` whose order file decodes. Throws `noAccess` for another
    /// folder or an unreadable file, `unsupportedFormat` for an unknown format, and `io` when the bookmark fails.
    /// Nothing is stored unless it succeeds. The `onGrant` action runs before it returns.
    func grant(pickedURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { () throws(OrderStoreError) in try self.grantNow(pickedURL) }) }
        }
        PlatformLog.order.notice("access to the order file granted")
        if let action = state.withLock({ $0.onGrant }) { await action() }
    }

    /// Runs after every successful grant.
    func onGrant(_ action: @escaping @Sendable () async -> Void) {
        state.withLock { $0.onGrant = action }
    }

    // MARK: On the queue

    private func resolve() -> URL? {
        let (resolved, container) = state.withLock { ($0.resolved, $0.container) }
        if resolved { return container }
        let opened = storage.load().flatMap(open)
        state.withLock { state in
            state.resolved = true
            state.container = opened
        }
        return opened
    }

    private func grantNow(_ picked: URL) throws(OrderStoreError) {
        guard picked.lastPathComponent == Self.folderName else {
            PlatformLog.order.notice("the picked folder is not the menu bar's group container")
            throw .noAccess
        }
        try Self.validate(picked)
        let bookmark: Data
        do {
            bookmark = try Self.bookmark(for: picked)
        } catch {
            PlatformLog.order.notice("the order file bookmark could not be made: \(error.localizedDescription, privacy: .private)")
            throw .io
        }
        guard let container = open(bookmark) else { throw .io }
        storage.save(bookmark)
        // An earlier container's scope stays started too: a store opened on it keeps using it for the run.
        state.withLock { state in
            state.resolved = true
            state.container = container
        }
    }

    /// Resolves a bookmark and starts its scope. A stale bookmark is made again from the resolved URL.
    private func open(_ bookmark: Data) -> URL? {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        } catch {
            PlatformLog.order.notice("the order file bookmark could not be resolved: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            PlatformLog.order.notice("the order file bookmark gave no access")
            return nil
        }
        if isStale {
            do {
                storage.save(try Self.bookmark(for: url))
                PlatformLog.order.notice("renewed the stale order file bookmark")
            } catch {
                PlatformLog.order.notice("the stale order file bookmark could not be renewed: \(error.localizedDescription, privacy: .private)")
            }
        }
        return url
    }

    /// The container's order file must be readable and in the measured format.
    private static func validate(_ container: URL) throws(OrderStoreError) {
        let data: Data
        do {
            data = try Data(contentsOf: container.appending(path: OrderStore27.preferencesFile))
        } catch {
            PlatformLog.order.notice("the picked order file could not be read: \(error.localizedDescription, privacy: .private)")
            throw .noAccess
        }
        _ = try OrderFileCodec().decode(file: data)
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
