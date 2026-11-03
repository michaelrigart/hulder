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

/// One owner and the items it was found with, left to right.
public struct OwnerItems: Equatable, Sendable {
    public var owner: ItemOwner
    public var items: [MenuBarItem]

    public init(owner: ItemOwner, items: [MenuBarItem]) {
        self.owner = owner
        self.items = items
    }
}

/// What one look at the bar found. Evidence only: what to keep from earlier passes is `InventoryMemory`'s call.
public struct ScanPass: Equatable, Sendable {
    /// Each owner the bar draws, with its drawn items; nil when the bar could not be read.
    public var drawn: [OwnerItems]?
    /// Each running app the live concealment hides and the bar doesn't draw, with the items its order-file entries
    /// give it, which may be none.
    public var concealed: [OwnerItems]
    /// Whether the pass was assembled with the order file's entries. Without them a named item still carries a
    /// made-up key, so a pass that says false must not be used to place anything.
    public var orderEntriesAvailable: Bool

    public init(drawn: [OwnerItems]?, concealed: [OwnerItems], orderEntriesAvailable: Bool) {
        self.drawn = drawn
        self.concealed = concealed
        self.orderEntriesAvailable = orderEntriesAvailable
    }

    /// The bar could not be read, or Accessibility was lost. It made no keys, so it never places anything.
    public static let unread = ScanPass(drawn: nil, concealed: [], orderEntriesAvailable: false)
}

public struct InventorySnapshot: Equatable, Sendable {
    public var items: [MenuBarItem]
    /// Owner ids whose items are not what the latest pass saw drawn or listed: the bar could not be read, or the
    /// owner is hidden and shown from what it last drew, or has no items at all.
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
    /// Each owner appears at most once in a pass, in `drawn` or in `concealed`.
    func scans() -> AsyncStream<ScanPass>
    func requestScan()
    func menuOpen() -> AsyncStream<Bool>
    func sessionEvents() -> AsyncStream<SessionEvent>

    var concealment: any ConcealmentBackend { get }
    var orderAccess: (any OrderAccess)? { get }
    /// Nil unless access is granted and the format is supported.
    func orderStore() async -> (any OrderStore)?
    func ownItemKey(in: InventorySnapshot) -> ItemKey?
}
