import AppKit
import os

/// The menu bar's bottom edge in Accessibility's top-left coordinates, read from `NSScreen` on the main
/// actor and cached so Accessibility queues can read it. Nil until the first read, and while no screen exists.
final class BarBottomEdge27: Sendable {
    private let stored = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let teardown = OSAllocatedUnfairLock<Teardown?>(initialState: nil)

    init() {
        Task { @MainActor [self] in start() }
    }

    deinit {
        teardown.withLock { $0 }?.run()
    }

    var value: Double? { stored.withLock { $0 } }

    @MainActor private func start() {
        refresh()
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let removal = Self.removal(of: token, from: center)
        teardown.withLock { $0 = removal }
    }

    private nonisolated static func removal(of token: any NSObjectProtocol, from center: NotificationCenter) -> Teardown {
        Teardown { center.removeObserver(token) }
    }

    @MainActor private func refresh() {
        let edge = NSScreen.main.map { Double($0.frame.maxY - $0.visibleFrame.maxY) }
        stored.withLock { $0 = edge }
    }
}
