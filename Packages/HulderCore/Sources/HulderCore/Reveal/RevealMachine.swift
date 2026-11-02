public enum RevealState: Equatable, Sendable {
    case hidden
    case revealed
    case revealedAll
}

extension RevealState {
    /// Whether the sections' items are held back while the bar is in this state.
    public func conceals(_ section: Section) -> Bool {
        switch (self, section) {
        case (.revealedAll, _), (_, .visible): false
        case (.hidden, _): true
        case (.revealed, let section): section == .alwaysHidden
        }
    }
}

public enum MenuTracking: Equatable, Sendable {
    case full
    case partial
    case unavailable
}

public enum RevealInput: Equatable, Sendable {
    case toggle
    case toggleAll
    case menuOpened
    case menuClosed
    case rehideDeadline(UInt64)
    case lockedOrAsleep
}

public enum RevealEffect: Equatable, Sendable {
    case scheduleRehide(token: UInt64, after: Duration)
    case cancelRehide
}

public enum RevealPolicy {
    public static func autoRehide(delay: RehideDelay, tracking: MenuTracking) -> Duration? {
        tracking == .full ? delay.duration : nil
    }
}

public struct RevealMachine: Equatable, Sendable {
    public private(set) var autoRehide: Duration?
    public private(set) var state: RevealState = .hidden
    public private(set) var isMenuOpen = false
    public private(set) var pendingRehide: UInt64?
    private var lastToken: UInt64 = 0

    public init(autoRehide: Duration?) {
        self.autoRehide = autoRehide
    }

    public mutating func handle(_ input: RevealInput) -> RevealEffect? {
        switch (state, input) {
        case (.hidden, .toggle):
            state = .revealed
            return schedule()
        case (.revealed, .toggle), (.revealedAll, .toggle):
            state = .hidden
            return cancel()
        case (.hidden, .toggleAll), (.revealed, .toggleAll):
            state = .revealedAll
            return schedule()
        case (.revealedAll, .toggleAll):
            state = .hidden
            return cancel()
        case (_, .menuOpened):
            isMenuOpen = true
            return cancel()
        case (.hidden, .menuClosed):
            isMenuOpen = false
            return nil
        case (.revealed, .menuClosed), (.revealedAll, .menuClosed):
            isMenuOpen = false
            return schedule()
        case (.revealed, .rehideDeadline(let token)), (.revealedAll, .rehideDeadline(let token)):
            guard token == pendingRehide, !isMenuOpen else { return nil }
            pendingRehide = nil
            state = .hidden
            return nil
        case (_, .lockedOrAsleep):
            state = .hidden
            return cancel()
        default:
            return nil
        }
    }

    /// Without a delay no deadline may stay pending; one already scheduled is withdrawn. With one, a bar that is
    /// revealed with nothing pending (the rehide was withdrawn, or automatic hiding was off) gets a deadline from
    /// now, unless a menu is open: closing it schedules one. A deadline already pending is left as it is, so a
    /// repeated call never pushes it back.
    public mutating func setAutoRehide(_ delay: Duration?) -> RevealEffect? {
        autoRehide = delay
        guard delay != nil else { return cancel() }
        guard state != .hidden, !isMenuOpen, pendingRehide == nil else { return nil }
        return schedule()
    }

    private mutating func schedule() -> RevealEffect? {
        guard let delay = autoRehide, !isMenuOpen else { return cancel() }
        lastToken += 1
        pendingRehide = lastToken
        return .scheduleRehide(token: lastToken, after: delay)
    }

    private mutating func cancel() -> RevealEffect? {
        guard pendingRehide != nil else { return nil }
        pendingRehide = nil
        return .cancelRehide
    }
}
