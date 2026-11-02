import ServiceManagement

@MainActor
final class LoginItem {
    private var applied: Bool?
    private var last: Task<Void, Never>?

    /// Follows the setting, one change at a time and in call order. It registers only an item that is not
    /// registered, so a choice made in System Settings › Login Items is never overridden.
    func apply(_ enabled: Bool) {
        guard enabled != applied else { return }
        applied = enabled
        let previous = last
        last = Task {
            await previous?.value
            let result = await Task.detached { Self.change(enabled) }.value
            let status = result.status
            if let failure = result.failure {
                Log.app.notice("Launch at login could not be changed: \(failure, privacy: .private)")
            } else {
                Log.app.notice("Launch at login is \(enabled ? "on" : "off", privacy: .public)")
            }
            if status == .requiresApproval {
                Log.app.notice("Launch at login needs approval in System Settings")
            } else if status == .notFound {
                Log.app.notice("Launch at login was not found by macOS")
            }
        }
    }

    private struct Applied: Sendable {
        var failure: String?
        var status: SMAppService.Status
    }

    /// The system's error text, if any, and the status afterwards.
    private nonisolated static func change(_ enabled: Bool) -> Applied {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            return Applied(failure: nil, status: service.status)
        } catch {
            return Applied(failure: error.localizedDescription, status: service.status)
        }
    }
}
