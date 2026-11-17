/// What the app does with each reading of the Accessibility grant. A grant that arrives in a process
/// that ran without it needs a fresh process, because observing started right after such a grant can
/// fail for every app. The app executes each action and reports whether a relaunch could start.
public struct GrantRule: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case use(Bool)
        case relaunch
        case nothing
    }

    private var inUse: Bool?
    private var ranWithoutGrant = false
    private var relaunching = false
    private var relaunchFailed = false

    public init() {}

    /// The action for a new reading. A reading made while a relaunch is under way changes nothing: the
    /// new copy reads the grant itself.
    public mutating func read(granted: Bool) -> Action {
        guard !relaunching else { return .nothing }
        guard granted else {
            ranWithoutGrant = true
            return use(false)
        }
        if ranWithoutGrant, !relaunchFailed {
            relaunching = true
            return .relaunch
        }
        ranWithoutGrant = false
        return use(true)
    }

    /// The outcome of a `.relaunch`. A relaunch that could not start is never tried again in this
    /// process: the grant is used here instead.
    public mutating func relaunchAttempted(started: Bool) -> Action {
        guard relaunching, !started else { return .nothing }
        relaunching = false
        relaunchFailed = true
        ranWithoutGrant = false
        return use(true)
    }

    private mutating func use(_ value: Bool) -> Action {
        guard inUse != value else { return .nothing }
        inUse = value
        return .use(value)
    }
}
