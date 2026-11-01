import Foundation
import HulderCore

public final class Platform27: MenuBarPlatform {
    static let accessibilityMissing = "Accessibility access is not granted."

    private let core: MenuBarClientCore
    private let trust = AccessibilityTrust27()
    private let apps = RunningApps27()
    private let session = SessionEvents27()
    private let scanner: MenuBarScanner27
    private let tracker: MenuTracker27

    public let ownAppID: AppID
    public let concealment: any ConcealmentBackend
    public let orderAccess: (any OrderAccess)? = nil

    init(core: MenuBarClientCore, ownAppID: AppID) {
        self.core = core
        self.ownAppID = ownAppID
        self.concealment = AssertionBackend27(core: core)
        let queue = AXQueue()
        let (trust, apps) = (trust, apps)
        // Task 13 supplies the order file's entries.
        scanner = MenuBarScanner27(queue: queue, trust: { trust.values() }, apps: { apps.values() }, entries: { nil })
        tracker = MenuTracker27(
            source: MenuWindowSource27(barEdge: BarBottomEdge27(), timeout: queue.messagingTimeout),
            queue: queue,
            trust: { trust.values() },
            processes: { apps.trackablePIDs() }
        )
    }

    public func capabilityChanges() -> AsyncStream<Capabilities> {
        let hiding = core.availability
        let trusted = trust.values()
        return AsyncStream { continuation in
            let task = Task {
                for await isTrusted in trusted {
                    continuation.yield(Capabilities(
                        hiding: hiding,
                        listing: isTrusted ? .available : .unavailable(Self.accessibilityMissing),
                        reordering: .unavailable("Not set up yet"),
                        menuTracking: isTrusted ? .full : .unavailable
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func runningApps() -> AsyncStream<Set<AppID>> { apps.values() }
    public func scans() -> AsyncStream<[AppScan]> { scanner.scans() }
    public func requestScan() { scanner.requestScan() }
    public func menuOpen() -> AsyncStream<Bool> { tracker.values() }

    public func sessionEvents() -> AsyncStream<SessionEvent> { session.events() }
    public func orderStore() async -> (any OrderStore)? { nil }
    public func ownItemKey(in snapshot: InventorySnapshot) -> ItemKey? {
        InventoryAssembly.ownItemKey(in: snapshot, ownAppID: ownAppID)
    }
}
