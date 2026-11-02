import Foundation
import HulderCore
import Synchronization

/// Access to the Menu Bar group container, which macOS protects. The user picks the folder once in an open
/// panel, and a security-scoped bookmark keeps that access across launches. Only `suggestedLocation` itself is
/// ever granted, whether picked or resolved from a stored bookmark, so one scope serves the run: it is started
/// once and stays started while Hulder runs. Bookmark and file work runs on one serial queue.
final class OrderAccess27: OrderAccess {
    static let bookmarkKey = "OrderContainerBookmark"
    static let folderName = "com.apple.MenuBar"
    static let wrongFolderReason = "Choose the com.apple.MenuBar folder in your Group Containers folder."

    /// Where the bookmark is kept: the app's defaults, or memory in tests.
    struct BookmarkStorage: Sendable {
        var load: @Sendable () -> Data?
        var save: @Sendable (Data) -> Void

        static let standard = BookmarkStorage(
            load: { UserDefaults.standard.data(forKey: bookmarkKey) },
            save: { UserDefaults.standard.set($0, forKey: bookmarkKey) }
        )
    }

    /// Starts a URL's security scope: the real call, or a recorded one in tests.
    struct SecurityScope: Sendable {
        var start: @Sendable (URL) -> Bool

        static let live = SecurityScope(start: { $0.startAccessingSecurityScopedResource() })
    }

    private struct State {
        /// Whether the stored bookmark has been resolved this run.
        var resolved = false
        var container: URL?
        var onGrant: (@Sendable () async -> Void)?
    }

    let suggestedLocation: URL
    private let storage: BookmarkStorage
    private let scope: SecurityScope
    private let queue = DispatchQueue(label: "com.michaelrigart.hulder.order-access", qos: .userInitiated)
    private let state = Mutex(State())

    init(
        storage: BookmarkStorage = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        scope: SecurityScope = .live
    ) {
        self.storage = storage
        self.scope = scope
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

    /// Accepts only `suggestedLocation` itself, whose order file must decode: writes to a copy elsewhere would be
    /// confirmed while the bar never moves. Throws `unsupportedFormat` with `wrongFolderReason` for any other
    /// folder, `noAccess` for an unreadable order file, `unsupportedFormat` for an unknown format, and `io` when
    /// the bookmark fails. Nothing is stored unless it succeeds. The `onGrant` action runs before it returns.
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

    /// The stored bookmark's folder with its scope started, resolved once a run. A bookmark that resolves outside
    /// the group container grants nothing, and stays stored until a valid grant replaces it.
    private func resolve() -> URL? {
        let (resolved, container) = state.withLock { ($0.resolved, $0.container) }
        if resolved { return container }
        var opened: URL?
        if let bookmark = storage.load().flatMap(resolveBookmark) {
            if isGroupContainer(bookmark.url) {
                opened = startScope(bookmark)
            } else {
                PlatformLog.order.notice("the stored order file bookmark is not the menu bar's group container; it needs a new grant")
            }
        }
        state.withLock { state in
            state.resolved = true
            state.container = opened
        }
        return opened
    }

    private func grantNow(_ picked: URL) throws(OrderStoreError) {
        guard isGroupContainer(picked) else {
            PlatformLog.order.notice("the picked folder is not the menu bar's group container")
            throw .unsupportedFormat(Self.wrongFolderReason)
        }
        _ = try OrderStore27.decodeFile(at: picked.appending(path: OrderStore27.preferencesFile))
        let bookmark: Data
        do {
            bookmark = try Self.bookmark(for: picked)
        } catch {
            PlatformLog.order.notice("the order file bookmark could not be made: \(error.localizedDescription, privacy: .private)")
            throw .io
        }
        guard let resolved = resolveBookmark(bookmark) else { throw .io }
        if state.withLock({ $0.container }) != nil {
            // A container is only ever the group container, so its scope already covers this folder.
            storage.save(bookmark)
            return
        }
        guard let container = startScope(resolved) else { throw .io }
        storage.save(bookmark)
        state.withLock { state in
            state.resolved = true
            state.container = container
        }
    }

    private struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    /// Resolves a bookmark without starting its scope.
    private func resolveBookmark(_ bookmark: Data) -> ResolvedBookmark? {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            PlatformLog.order.notice("the order file bookmark could not be resolved: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Starts the bookmark's scope. A stale bookmark is then made again from the resolved URL.
    private func startScope(_ resolved: ResolvedBookmark) -> URL? {
        guard scope.start(resolved.url) else {
            PlatformLog.order.notice("the order file bookmark gave no access")
            return nil
        }
        if resolved.isStale {
            do {
                storage.save(try Self.bookmark(for: resolved.url))
                PlatformLog.order.notice("renewed the stale order file bookmark")
            } catch {
                PlatformLog.order.notice("the stale order file bookmark could not be renewed: \(error.localizedDescription, privacy: .private)")
            }
        }
        return resolved.url
    }

    /// R40: writes to any folder but the group container itself would be confirmed while the bar never moves.
    private func isGroupContainer(_ url: URL) -> Bool {
        Self.canonicalPath(url) == Self.canonicalPath(suggestedLocation)
    }

    /// The resolved, standardized path, so that symlinks and spelling can't make one folder look like two.
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
