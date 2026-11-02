import AppKit
import HulderCore
import HulderPlatform27

@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let send: @MainActor (RevealInput) -> Void
    private let showLayout: @MainActor () -> Void
    private let showSettings: @MainActor () -> Void
    private let hidingFailure: @MainActor () -> FailureKind?

    init(
        send: @escaping @MainActor (RevealInput) -> Void,
        showLayout: @escaping @MainActor () -> Void,
        showSettings: @escaping @MainActor () -> Void,
        hidingFailure: @escaping @MainActor () -> FailureKind?
    ) {
        self.send = send
        self.showLayout = showLayout
        self.showSettings = showSettings
        self.hidingFailure = hidingFailure
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = HulderPlatform27.statusItemAutosaveName
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setState(.hidden)
    }

    func setState(_ state: RevealState) {
        let symbol = state == .hidden ? "chevron.left" : "chevron.right"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hulder")
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else {
            send(.toggle)
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else if event.modifierFlags.contains(.option) {
            send(.toggleAll)
        } else {
            send(.toggle)
        }
    }

    @objc private func openLayout() { showLayout() }
    @objc private func openSettings() { showSettings() }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Layout…", action: #selector(openLayout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        if let failure = hidingFailure() {
            menu.addItem(.separator())
            menu.addItem(withTitle: failure.message, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hulder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The menu is attached only for this click: with one set, the button shows it instead of
        // sending its action.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
