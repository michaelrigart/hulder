import HulderCore

public final class UnsupportedPlatform: MenuBarPlatform {
    public static let defaultReason = "Hulder needs macOS 27 or later."

    private let capabilities: Capabilities

    public let ownAppID: AppID
    public let concealment: any ConcealmentBackend
    public let orderAccess: (any OrderAccess)? = nil

    public init(reason: String, ownAppID: AppID) {
        let unavailable = Availability.unavailable(reason)
        self.capabilities = Capabilities(hiding: unavailable, listing: unavailable, reordering: unavailable, menuTracking: .unavailable)
        self.ownAppID = ownAppID
        self.concealment = UnsupportedConcealment(reason: reason)
    }

    public func capabilityChanges() -> AsyncStream<Capabilities> { Self.single(capabilities) }
    public func runningApps() -> AsyncStream<Set<AppID>> { Self.single([]) }
    public func scans() -> AsyncStream<[AppScan]> { AsyncStream { _ in } }
    public func requestScan() {}
    public func menuOpen() -> AsyncStream<Bool> { Self.single(false) }
    public func sessionEvents() -> AsyncStream<SessionEvent> { AsyncStream { _ in } }
    public func orderStore() async -> (any OrderStore)? { nil }
    public func ownItemKey(in: InventorySnapshot) -> ItemKey? { nil }

    private static func single<Element: Sendable>(_ element: Element) -> AsyncStream<Element> {
        AsyncStream { continuation in continuation.yield(element) }
    }
}

private struct UnsupportedConcealment: ConcealmentBackend {
    let reason: String

    func prepare(_ list: AllowList) async throws -> ConcealmentToken { throw ConcealmentFailure.unavailable(reason) }
    func activate(_ token: ConcealmentToken) async throws { throw ConcealmentFailure.unavailable(reason) }
    func invalidate(_ token: ConcealmentToken) async {}
}
