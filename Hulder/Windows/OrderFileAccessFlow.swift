import AppKit
import HulderCore
import Observation

/// Asks for access to the order file. It decides nothing: whether access exists comes from `OrderAccess`.
/// The Layout window and Settings › Permissions share it.
@MainActor @Observable
final class OrderFileAccessFlow {
    /// Nil until `OrderAccess.isGranted()` has answered, and always when the platform offers no access.
    private(set) var granted: Bool?
    private(set) var picking = false
    private(set) var problem: String?

    @ObservationIgnored private let access: (any OrderAccess)?

    init(access: (any OrderAccess)?) {
        self.access = access
    }

    var canAsk: Bool { access != nil && granted == false }

    func refresh() async {
        granted = await access?.isGranted()
    }

    /// Lets the user pick the folder, then grants it. `onGranted` runs after a grant succeeds.
    func allow(onGranted: @escaping () -> Void) {
        guard let access, !picking else { return }
        picking = true
        problem = nil
        Task {
            defer { picking = false }
            guard let url = await Self.pickFolder(startingAt: access.suggestedLocation.deletingLastPathComponent())
            else { return }
            do {
                try await access.grant(pickedURL: url)
                granted = await access.isGranted()
                onGranted()
            } catch {
                problem = Self.text(for: error)
            }
        }
    }

    /// The folder itself is protected, so the panel starts at its parent and the user picks it there.
    private static func pickFolder(startingAt directory: URL) async -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the com.apple.MenuBar folder, then click Allow."
        panel.prompt = "Allow"
        return await panel.begin() == .OK ? panel.url : nil
    }

    private static func text(for error: any Error) -> String {
        switch error as? OrderStoreError {
        case .unsupportedFormat(let text)?: text
        case .noAccess?: "Hulder couldn't open that folder."
        default: "Hulder couldn't set up reordering."
        }
    }
}
