import Foundation

public struct Capabilities: Equatable, Sendable {
    public var hiding: Availability
    /// The Accessibility state.
    public var listing: Availability
    public var reordering: Availability
    public var menuTracking: MenuTracking

    public init(hiding: Availability, listing: Availability, reordering: Availability, menuTracking: MenuTracking) {
        self.hiding = hiding
        self.listing = listing
        self.reordering = reordering
        self.menuTracking = menuTracking
    }
}

public enum ScanResult: Equatable, Sendable {
    case complete([MenuBarItem])
    case timedOut
    case failed
}

public struct AppScan: Equatable, Sendable {
    public var owner: ItemOwner
    public var result: ScanResult

    public init(owner: ItemOwner, result: ScanResult) {
        self.owner = owner
        self.result = result
    }
}

public struct InventorySnapshot: Equatable, Sendable {
    public var items: [MenuBarItem]
    /// Owner ids whose items are the last known ones, because the latest scan did not complete.
    public var stale: Set<String>

    public init(items: [MenuBarItem], stale: Set<String>) {
        self.items = items
        self.stale = stale
    }

    public static let empty = InventorySnapshot(items: [], stale: [])
}

public enum SessionEvent: Sendable {
    case lockedOrAsleep
}

public protocol OrderAccess: Sendable {
    func isGranted() async -> Bool
    var suggestedLocation: URL { get }
    func grant(pickedURL: URL) async throws
}

public protocol MenuBarPlatform: Sendable {
    var ownAppID: AppID { get }

    /// Emits again whenever a capability changes: Accessibility granted or revoked, order-file access
    /// granted, or the order format found unsupported.
    ///
    /// Every stream that carries state (`capabilityChanges`, `runningApps`, `menuOpen`) emits its
    /// current value first, then the changes.
    func capabilityChanges() -> AsyncStream<Capabilities>
    func runningApps() -> AsyncStream<Set<AppID>>
    /// Each pass holds at most one `AppScan` per owner id.
    func scans() -> AsyncStream<[AppScan]>
    func requestScan()
    func menuOpen() -> AsyncStream<Bool>
    func sessionEvents() -> AsyncStream<SessionEvent>

    var concealment: any ConcealmentBackend { get }
    var orderAccess: (any OrderAccess)? { get }
    /// Nil unless access is granted and the format is supported.
    func orderStore() async -> (any OrderStore)?
    func ownItemKey(in: InventorySnapshot) -> ItemKey?
}
