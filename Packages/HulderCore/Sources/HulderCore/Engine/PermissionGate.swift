/// What the Accessibility state and the install location allow. The driver is fed only once Accessibility
/// has been granted in this run, and stays fed after a revocation; it is never fed from outside
/// `/Applications`, where the notice to move Hulder shows instead. The install location is fixed at creation. Onboarding is for launch only: it shows
/// while the grant is missing, never after a revocation and never where hiding itself is unavailable.
public struct PermissionGate: Equatable, Sendable {
    public private(set) var feedsDriver = false
    public private(set) var showsOnboarding = false
    public private(set) var showsMoveNotice = false

    public let installedInApplications: Bool

    public init(installedInApplications: Bool = true) {
        self.installedInApplications = installedInApplications
    }

    public mutating func update(_ capabilities: Capabilities) {
        if installedInApplications, capabilities.listing == .available { feedsDriver = true }
        showsMoveNotice = !installedInApplications && capabilities.hiding == .available
        showsOnboarding = installedInApplications && !feedsDriver && capabilities.hiding == .available
    }
}
