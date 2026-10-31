public enum RevealState: Equatable, Sendable {
    case hidden
    case revealed
    case revealedAll
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
    public var autoRehide: Duration?
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
