import AppKit
import SwiftUI

enum WindowKind: CaseIterable {
    case layout
    case settings
    case onboarding

    var title: String {
        switch self {
        case .layout: "Layout"
        case .settings: "Settings"
        case .onboarding: "Welcome to Hulder"
        }
    }

    /// A resizable window takes its minimum and ideal size from its content.
    var isResizable: Bool { self == .layout }
}

@MainActor
final class WindowPresenter {
    private let content: @MainActor (WindowKind) -> AnyView
    private var windows: [WindowKind: NSWindow] = [:]

    init(content: @escaping @MainActor (WindowKind) -> AnyView) {
        self.content = content
    }

    func show(_ kind: WindowKind) {
        let window: NSWindow
        if let open = windows[kind], open.isVisible {
            window = open
        } else {
            window = makeWindow(kind)
            windows[kind] = window
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
    }

    func close(_ kind: WindowKind) {
        windows.removeValue(forKey: kind)?.close()
    }

    private func makeWindow(_ kind: WindowKind) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content(kind)))
        window.title = kind.title
        window.styleMask = kind.isResizable ? [.titled, .closable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
