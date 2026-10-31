#if DEBUG
import AppKit

/// A small floating panel titled "Hulder probe" with a step description and a Continue
/// button. The probe is launched with `open`, so there is no terminal to read from.
@MainActor
final class ProbePanel: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Hulder probe"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        label.preferredMaxLayoutWidth = 380
        let button = NSButton(title: "Continue", target: self, action: #selector(continueClicked))
        button.keyEquivalent = "\r"

        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        panel.contentView = stack
    }

    /// Shows `message` and returns when Continue is clicked.
    func wait(_ message: String) async {
        PlatformLog.probe.notice("waiting for Continue: \(message, privacy: .public)")
        label.stringValue = message
        panel.setContentSize(stack.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
        NSApp.activate()
        await withCheckedContinuation { continuation = $0 }
        panel.orderOut(nil)
    }

    @objc private func continueClicked() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
