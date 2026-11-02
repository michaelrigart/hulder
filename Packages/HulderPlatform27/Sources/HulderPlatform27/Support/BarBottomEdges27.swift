import AppKit
import os

/// The menu bar's bottom edge on each screen, in Accessibility's top-left coordinates. It is read from the screens on
/// the main actor, and cached so Accessibility queues can read it. Empty until the first read, and while no screen
/// exists.
final class BarBottomEdges27: Sendable {
    private let stored = OSAllocatedUnfairLock<[BarEdge]>(initialState: [])
    private let teardown = OSAllocatedUnfairLock<Teardown?>(initialState: nil)

    init() {
        Task { @MainActor [self] in start() }
    }

    deinit {
        teardown.withLock { $0 }?.run()
    }

    var value: [BarEdge] { stored.withLock { $0 } }

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
        let thickness = NSStatusBar.system.thickness
        let screens = NSScreen.screens.map {
            ScreenBar(
                frame: $0.frame,
                barHeight: BarEdges.barHeight(
                    reserved: $0.frame.maxY - $0.visibleFrame.maxY, safeAreaTop: $0.safeAreaInsets.top,
                    statusBarThickness: thickness))
        }
        let edges = BarEdges.edges(for: screens)
        stored.withLock { $0 = edges }
    }
}
