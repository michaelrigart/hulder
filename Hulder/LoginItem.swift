import ServiceManagement

@MainActor
final class LoginItem {
    private var applied: Bool?
    private var last: Task<Void, Never>?

    /// Registers or unregisters the app as a login item, one change at a time and in call order.
    func apply(_ enabled: Bool) {
        guard enabled != applied else { return }
        applied = enabled
        let previous = last
        last = Task {
            await previous?.value
            let failure = await Task.detached { Self.change(enabled) }.value
            if let failure {
                Log.app.notice("Launch at login could not be changed: \(failure, privacy: .private)")
            } else {
                Log.app.notice("Launch at login is \(enabled ? "on" : "off", privacy: .public)")
            }
        }
    }

    /// The system's error text, or nil on success.
    private nonisolated static func change(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
