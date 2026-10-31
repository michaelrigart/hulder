@MainActor
public final class ConcealmentDriver {
    private struct Send: Sendable {
        let generation: UInt64
        let plan: Concealment
    }

    private let controller: ConcealmentController
    private let own: AppID
    private let onOutcome: @MainActor (ApplyOutcome) -> Void
    private let sends: AsyncStream<Send>.Continuation
    private var pipeline: Task<Void, Never>!

    private var layout = Layout()
    private var state = RevealState.hidden
    private var running: Set<AppID> = []
    private var released = false
    private var generation: UInt64 = 0

    private(set) var lastSent: Concealment?
    private(set) var sentCount = 0

    public init(
        controller: ConcealmentController,
        own: AppID,
        onOutcome: @escaping @MainActor (ApplyOutcome) -> Void
    ) {
        self.controller = controller
        self.own = own
        self.onOutcome = onOutcome
        let (stream, continuation) = AsyncStream.makeStream(of: Send.self)
        sends = continuation
        // One task queues every request, in the order `update` made them. The controller's own queue then
        // lets the newest win; its outcomes come back through `finish`.
        pipeline = Task { [weak self] in
            for await send in stream {
                await controller.submit(send.plan) { outcome in
                    Task { @MainActor in self?.finish(outcome, of: send.generation) }
                }
            }
        }
    }

    deinit {
        sends.finish()
    }

    public func update(layout: Layout? = nil, state: RevealState? = nil, running: Set<AppID>? = nil) {
        guard !released else { return }
        if let layout { self.layout = layout }
        if let state { self.state = state }
        if let running { self.running = running }

        let plan = ConcealmentPlanner.plan(layout: self.layout, state: self.state, running: self.running, own: own)
        guard plan != lastSent else { return }
        lastSent = plan
        generation += 1
        sentCount += 1
        sends.yield(Send(generation: generation, plan: plan))
    }

    /// Ends the concealment for good. It is terminal: later updates are ignored, and outcomes still on
    /// their way are dropped.
    public func releaseAll() async {
        released = true
        generation += 1
        lastSent = nil
        sends.finish()
        await controller.releaseAll()
        await pipeline.value
    }

    private func finish(_ outcome: ApplyOutcome, of request: UInt64) {
        guard request == generation else { return }
        if case .failed = outcome { lastSent = nil }
        onOutcome(outcome)
    }
}
