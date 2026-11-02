/// What a scan pass does with the apps the layout hasn't seen.
enum FirstSightingMode: Equatable, Sendable {
    /// Record no new app; a later pass sees it as new again. Known apps stay current.
    case wait
    /// Record new apps in the default section and place nothing.
    case recordOnly
    /// Record new apps and place their items from this pass's inventory.
    case recordAndPlace
}

/// When a new app may be recorded. Recording it ends its being new, so it happens only when the same pass can place
/// it, or when placing is known to be impossible: a later grant must not move icons the user arranged since.
///
/// A pure function of the current inputs, so no capability event and no hiding can lose a sighting: a new app that
/// no pass could place stays unknown to the layout, and the next pass sees it again.
enum FirstSightingRule {
    static func mode(
        reordering: Availability, hasController: Bool, controllerUnobtainable: Bool, passReadOrderFile: Bool
    ) -> FirstSightingMode {
        // With a controller the pass's keys must be the order file's: a pass without it made them up.
        if hasController { return passReadOrderFile ? .recordAndPlace : .wait }
        switch reordering {
        case .available: return controllerUnobtainable ? .recordOnly : .wait
        case .unavailable: return reordering == .notChecked ? .wait : .recordOnly
        }
    }
}
