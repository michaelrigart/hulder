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
    /// Whether `lastSent` is a plan whose application failed. It is not sent again until something the
    /// user did changes: the reveal state or a section.
    private var lastSentFailed = false

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
        var userChange = false
        if let layout {
            userChange = Self.sectionsDiffer(self.layout, layout)
            self.layout = layout
        }
        if let state {
            userChange = userChange || state != self.state
            self.state = state
        }
        if let running { self.running = running }

        let plan = ConcealmentPlanner.plan(layout: self.layout, state: self.state, running: self.running, own: own)
        guard plan != lastSent || (lastSentFailed && userChange) else { return }
        lastSent = plan
        lastSentFailed = false
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
        lastSentFailed = false
        sends.finish()
        await controller.releaseAll()
        await pipeline.value
    }

    /// Whether the default section or the section of an app known to both layouts changed.
    private static func sectionsDiffer(_ old: Layout, _ new: Layout) -> Bool {
        if old.defaultSection != new.defaultSection { return true }
        return new.apps.contains { app, known in
            old.apps[app].map { $0.section != known.section } ?? false
        }
    }

    private func finish(_ outcome: ApplyOutcome, of request: UInt64) {
        guard request == generation else { return }
        if case .failed = outcome { lastSentFailed = true }
        onOutcome(outcome)
    }
}
