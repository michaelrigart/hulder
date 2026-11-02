/// What the Accessibility state allows. The driver is fed only once Accessibility has been granted in
/// this run, and stays fed after a revocation. Onboarding is for launch only: it shows while the grant
/// is missing, never after a revocation and never where hiding itself is unavailable.
public struct PermissionGate: Equatable, Sendable {
    public private(set) var feedsDriver = false
    public private(set) var showsOnboarding = false

    public init() {}

    public mutating func update(_ capabilities: Capabilities) {
        if capabilities.listing == .available { feedsDriver = true }
        showsOnboarding = !feedsDriver && capabilities.hiding == .available
    }
}
