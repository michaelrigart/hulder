@MainActor
public final class ConcealmentDriver {
    private let controller: ConcealmentController
    private let own: AppID
    private let onOutcome: @MainActor (ApplyOutcome) -> Void

    private var layout = Layout()
    private var state = RevealState.hidden
    private var running: Set<AppID> = []

    private var lastSent: Concealment?
    private var generation: UInt64 = 0

    public init(
        controller: ConcealmentController,
        own: AppID,
        onOutcome: @escaping @MainActor (ApplyOutcome) -> Void
    ) {
        self.controller = controller
        self.own = own
        self.onOutcome = onOutcome
    }

    public func update(layout: Layout? = nil, state: RevealState? = nil, running: Set<AppID>? = nil) {
        if let layout { self.layout = layout }
        if let state { self.state = state }
        if let running { self.running = running }

        let plan = ConcealmentPlanner.plan(layout: self.layout, state: self.state, running: self.running, own: own)
        guard plan != lastSent else { return }
        lastSent = plan
        generation += 1
        let sent = generation
        let controller = controller
        Task {
            let outcome = await controller.apply(plan)
            self.finish(outcome, of: sent)
        }
    }

    public func releaseAll() async {
        generation += 1
        lastSent = nil
        await controller.releaseAll()
    }

    private func finish(_ outcome: ApplyOutcome, of request: UInt64) {
        guard request == generation else { return }
        if case .failed = outcome { lastSent = nil }
        onOutcome(outcome)
    }
}
