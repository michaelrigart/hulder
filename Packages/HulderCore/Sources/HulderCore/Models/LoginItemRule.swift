/// The state of the login item, as `SMAppService.Status` reports it.
public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    /// Registered, but turned off by the user in System Settings › General › Login Items.
    case requiresApproval
    case notFound
}

public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
    case none
}

public enum LoginItemRule {
    /// Registers only an item that is not registered, so a choice made in System Settings is never
    /// overridden. Unregisters an item that is registered, whether or not it is approved.
    public static func action(enabled: Bool, status: LoginItemStatus) -> LoginItemAction {
        if enabled {
            return status == .notRegistered ? .register : .none
        }
        return status == .enabled || status == .requiresApproval ? .unregister : .none
    }
}
