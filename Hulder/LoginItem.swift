import HulderCore
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginItem {
    /// Whether the user turned Hulder off in System Settings › General › Login Items. It follows every
    /// change `apply` makes and every `refresh`, so Settings shows it without a lagging second read.
    private(set) var turnedOffInSystemSettings = false

    @ObservationIgnored private var applied: Bool?
    @ObservationIgnored private var last: Task<Void, Never>?

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
            turnedOffInSystemSettings = status == .requiresApproval
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

    /// Reads the status again, after any change in flight, for a change made in System Settings. The
    /// status is read off the main actor.
    func refresh() async {
        let previous = last
        let task = Task {
            await previous?.value
            let status = await Task.detached { LoginItemStatus(SMAppService.mainApp.status) }.value
            turnedOffInSystemSettings = status == .requiresApproval
        }
        last = task
        await task.value
    }

    private struct Applied: Sendable {
        var failure: String?
        var status: LoginItemStatus
    }

    /// The system's error text, if any, and the status afterwards.
    private nonisolated static func change(_ enabled: Bool) -> Applied {
        let service = SMAppService.mainApp
        do {
            switch LoginItemRule.action(enabled: enabled, status: LoginItemStatus(service.status)) {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .none: break
            }
            return Applied(failure: nil, status: LoginItemStatus(service.status))
        } catch {
            return Applied(failure: error.localizedDescription, status: LoginItemStatus(service.status))
        }
    }
}

extension LoginItemStatus {
    nonisolated init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}
