import Foundation
import HulderCore
import os

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
            processes: { apps.trackablePIDs() },
            launched: { apps.finishedLaunching() }
        )
    }

    /// Menu tracking can't be better than the Accessibility state, even for the moment the two sources disagree.
    static func capabilities(hiding: Availability, trusted: Bool, tracking: MenuTracking) -> Capabilities {
        Capabilities(
            hiding: hiding,
            listing: trusted ? .available : .unavailable(accessibilityMissing),
            reordering: .unavailable("Not set up yet"),
            menuTracking: trusted ? tracking : .unavailable
        )
    }

    /// The Accessibility state and menu tracking, each from its own source; a change in either emits again.
    public func capabilityChanges() -> AsyncStream<Capabilities> {
        let hiding = core.availability
        let trusted = trust.values()
        let tracking = tracker.trackingChanges()
        return AsyncStream { continuation in
            struct Latest {
                var trusted: Bool?
                var tracking: MenuTracking?
                var emitted: Capabilities?
            }
            let latest = OSAllocatedUnfairLock(initialState: Latest())
            let update: @Sendable (@Sendable (inout Latest) -> Void) -> Void = { change in
                latest.withLock { latest in
                    change(&latest)
                    guard let isTrusted = latest.trusted, let tracking = latest.tracking else { return }
                    let capabilities = Self.capabilities(hiding: hiding, trusted: isTrusted, tracking: tracking)
                    guard capabilities != latest.emitted else { return }
                    latest.emitted = capabilities
                    continuation.yield(capabilities)
                }
            }
            let tasks = [
                Task { for await isTrusted in trusted { update { $0.trusted = isTrusted } } },
                Task { for await value in tracking { update { $0.tracking = value } } },
            ]
            continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
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
