import Foundation
import HulderCore
import os

public final class Platform27: MenuBarPlatform {
    static let accessibilityMissing = "Accessibility access is not granted."

    private let core: MenuBarClientCore
    private let backend: AssertionBackend27
    private let trust = AccessibilityTrust27()
    private let apps = RunningApps27()
    private let session = SessionEvents27()
    private let scanner: MenuBarScanner27
    let tracker: MenuTracker27
    let orderFile: OrderFile27

    public let ownAppID: AppID
    public let concealment: any ConcealmentBackend
    public let orderAccess: (any OrderAccess)?

    init(core: MenuBarClientCore, ownAppID: AppID) {
        self.core = core
        self.ownAppID = ownAppID
        // The scanner needs the backend's answer and the backend needs to ask the scanner for a scan.
        let scannerBox = OSAllocatedUnfairLock<MenuBarScanner27?>(initialState: nil)
        let backend = AssertionBackend27(core: core, onConcealmentChange: { scannerBox.withLock { $0 }?.requestScan() })
        self.backend = backend
        self.concealment = backend
        let queue = AXQueue()
        let access = OrderAccess27()
        let orderFile = OrderFile27(
            container: { await access.container() },
            makeBackend: { ContainerPreferences(container: $0) },
            backups: Self.orderBackups,
            drawnKeys: OrderStore27.drawnKeysReader(queue: queue, own: ownAppID)
        )
        orderAccess = access
        self.orderFile = orderFile
        let (trust, apps) = (trust, apps)
        let scanner = MenuBarScanner27(
            queue: queue, trust: { trust.values() }, apps: { apps.values() }, entries: { orderFile.entries() },
            concealed: { await backend.concealedApps(among: $0) }, own: ownAppID
        )
        self.scanner = scanner
        tracker = MenuTracker27(
            source: MenuWindowSource27(barEdges: BarBottomEdges27(), timeout: queue.messagingTimeout),
            queue: queue,
            trust: { trust.values() },
            processes: { apps.trackablePIDs() },
            launched: { apps.finishedLaunching() },
            identities: { apps.trackableIdentities() },
            owners: { scanner.inventoryOwners() }
        )
        access.onGrant { await orderFile.evaluate() }
        scannerBox.withLock { $0 = scanner }
        orderFile.start(onOrderChange: { scanner.requestScan() })
    }

    /// `~/Library/Application Support/com.michaelrigart.hulder/OrderBackups`.
    static var orderBackups: URL {
        URL.applicationSupportDirectory.appending(path: HulderCore.bundleID).appending(path: "OrderBackups")
    }

    /// Menu tracking can't be better than the Accessibility state, even for the moment the two sources disagree.
    static func capabilities(
        hiding: Availability, trusted: Bool, tracking: MenuTracking, reordering: Availability
    ) -> Capabilities {
        Capabilities(
            hiding: hiding,
            listing: trusted ? .available : .unavailable(accessibilityMissing),
            reordering: reordering,
            menuTracking: trusted ? tracking : .unavailable
        )
    }

    /// The Accessibility state, menu tracking and reordering, each from its own source; a change in any emits again.
    /// Reordering doesn't hold the others back: until the order file is checked, it is unavailable as not checked.
    public func capabilityChanges() -> AsyncStream<Capabilities> {
        let hiding = core.availability
        let trusted = trust.values()
        let tracking = tracker.trackingChanges()
        let reordering = orderFile.reorderingChanges()
        return AsyncStream { continuation in
            struct Latest {
                var trusted: Bool?
                var tracking: MenuTracking?
                var reordering = Availability.notChecked
                var emitted: Capabilities?
            }
            let latest = OSAllocatedUnfairLock(initialState: Latest())
            let update: @Sendable (@Sendable (inout Latest) -> Void) -> Void = { change in
                latest.withLock { latest in
                    change(&latest)
                    guard let isTrusted = latest.trusted, let tracking = latest.tracking else { return }
                    let capabilities = Self.capabilities(
                        hiding: hiding, trusted: isTrusted, tracking: tracking, reordering: latest.reordering
                    )
                    guard capabilities != latest.emitted else { return }
                    latest.emitted = capabilities
                    continuation.yield(capabilities)
                }
            }
            let tasks = [
                Task { for await isTrusted in trusted { update { $0.trusted = isTrusted } } },
                Task { for await value in tracking { update { $0.tracking = value } } },
                Task { for await value in reordering { update { $0.reordering = value } } },
            ]
            continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        }
    }

    public func runningApps() -> AsyncStream<Set<AppID>> { apps.values() }
    public func scans() -> AsyncStream<[AppScan]> { scanner.scans() }
    public func requestScan() { scanner.requestScan() }
    public func menuOpen() -> AsyncStream<Bool> { tracker.values() }

    /// The apps among `running` that the confirmed concealment hides.
    func concealedApps(among running: Set<AppID>) async -> Set<AppID> {
        await backend.concealedApps(among: running)
    }

    public func sessionEvents() -> AsyncStream<SessionEvent> { session.events() }
    public func orderStore() async -> (any OrderStore)? { await orderFile.availableStore() }
    public func ownItemKey(in snapshot: InventorySnapshot) -> ItemKey? {
        InventoryAssembly.ownItemKey(in: snapshot, ownAppID: ownAppID)
    }
}
