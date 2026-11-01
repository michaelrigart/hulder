import Foundation
import HulderCore

public final class Platform27: MenuBarPlatform {
    static let accessibilityMissing = "Accessibility access is not granted."

    private let core: MenuBarClientCore
    private let trust = AccessibilityTrust27()
    private let apps = RunningApps27()
    private let session = SessionEvents27()

    public let ownAppID: AppID
    public let concealment: any ConcealmentBackend
    public let orderAccess: (any OrderAccess)? = nil

    init(core: MenuBarClientCore, ownAppID: AppID) {
        self.core = core
        self.ownAppID = ownAppID
        self.concealment = AssertionBackend27(core: core)
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
                        menuTracking: .unavailable
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func runningApps() -> AsyncStream<Set<AppID>> { apps.values() }
    public func scans() -> AsyncStream<[AppScan]> { AsyncStream { _ in } }
    public func requestScan() {}

    public func menuOpen() -> AsyncStream<Bool> {
        AsyncStream { continuation in continuation.yield(false) }
    }

    public func sessionEvents() -> AsyncStream<SessionEvent> { session.events() }
    public func orderStore() async -> (any OrderStore)? { nil }
    public func ownItemKey(in: InventorySnapshot) -> ItemKey? { nil }
}
