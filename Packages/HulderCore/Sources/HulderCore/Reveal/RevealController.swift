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
        apply(machine.handle(input))
    }

    public func setAutoRehide(_ delay: Duration?) {
        apply(machine.setAutoRehide(delay))
    }

    private func apply(_ effect: RevealEffect?) {
        if machine.state != state {
            state = machine.state
            onChange(state)
        }
        guard let effect else { return }
        rehideTask?.cancel()
        rehideTask = nil
        if case .scheduleRehide(let token, let delay) = effect {
            let sleep = clock.sleeper(after: delay)
            rehideTask = Task { [weak self] in
                do { try await sleep() } catch { return }
                self?.send(.rehideDeadline(token))
            }
        }
    }
}
