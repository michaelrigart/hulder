@MainActor
public final class RevealController {
    public private(set) var state: RevealState
    private var machine: RevealMachine
    private let clock: any Clock<Duration>
    private let onChange: @MainActor (RevealState) -> Void
    private var rehideTask: Task<Void, Never>?

    public init(
        machine: RevealMachine,
        clock: any Clock<Duration>,
        onChange: @escaping @MainActor (RevealState) -> Void
    ) {
        self.machine = machine
        self.state = machine.state
        self.clock = clock
        self.onChange = onChange
    }

    public func send(_ input: RevealInput) {
        let effect = machine.handle(input)
        if machine.state != state {
            state = machine.state
            onChange(state)
        }
        guard let effect else { return }
        rehideTask?.cancel()
        rehideTask = nil
        if case .scheduleRehide(let token, let delay) = effect {
            let sleep = Self.sleeper(on: clock, for: delay)
            rehideTask = Task { [weak self] in
                do { try await sleep() } catch { return }
                self?.send(.rehideDeadline(token))
            }
        }
    }

    // The deadline is fixed here, when the effect runs, not when the task first gets to run.
    private static func sleeper<C: Clock>(
        on clock: C,
        for delay: Duration
    ) -> @Sendable () async throws -> Void where C.Duration == Duration {
        let deadline = clock.now.advanced(by: delay)
        return { try await clock.sleep(until: deadline, tolerance: nil) }
    }

    public func setAutoRehide(_ delay: Duration?) {
        machine.autoRehide = delay
    }
}
