/// The state of the login item, as `SMAppService.Status` reports it.
public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    /// Registered, but turned off by the user in System Settings › General › Login Items.
    case requiresApproval
    /// What macOS reports for a main app that was never registered.
    case notFound
}

public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
    case none
}

public enum LoginItemRule {
    /// Registers an item that is not registered, including a main app macOS has never seen (`notFound`), but never
    /// one waiting for approval, so a choice made in System Settings is not overridden. Unregisters an item that is
    /// registered, whether or not it is approved.
    public static func action(enabled: Bool, status: LoginItemStatus) -> LoginItemAction {
        if enabled {
            return status == .notRegistered || status == .notFound ? .register : .none
        }
        return status == .enabled || status == .requiresApproval ? .unregister : .none
    }
}
