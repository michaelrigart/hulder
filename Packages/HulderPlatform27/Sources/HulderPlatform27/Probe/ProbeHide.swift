#if DEBUG
import AppKit
import HulderCore
import os

/// A continuation that the first of two racing callers resumes.
private final class OneShot: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    /// Whether this call was the first, and so resumed it.
    @discardableResult
    func resume(with value: Bool) -> Bool {
        guard let taken = continuation.withLock({ state -> CheckedContinuation<Bool, Never>? in
            defer { state = nil }
            return state
        }) else { return false }
        taken.resume(returning: value)
        return true
    }
}

extension ProbeRunner {
    /// How long `hide-cancel` waits after starting an activation before it invalidates. The backend gives no
    /// signal that the framework has been called, and an invalidate that comes first means it never is.
    static let earlyInvalidateDelay: Duration = .milliseconds(5)

    /// How long the probe waits for the framework's queue to run an invalidate.
    static let drainTimeout: Duration = .seconds(3)

    enum Activation: Sendable {
        case completed
        case failed(String)
        case timedOut

        /// A silent agent still gets measured: only a reported failure stops the step.
        var proceeds: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    // MARK: Building blocks

    /// The shipped backend, or one whose system items stop at `maxSystemItem`.
    private func backend(maxSystemItem: Int?) -> any ConcealmentBackend {
        guard let maxSystemItem else { return platform.concealment }
        return AssertionBackend27(core: core) { list in
            let translated = AllowListTranslation.arguments(for: list)
            return (translated.bundleIDs, list.keepsAllSystemItems ? Array(0...maxSystemItem) : [])
        }
    }

    /// Every running app except `bundleIDs`, plus Hulder.
    private func allowList(hiding bundleIDs: [String], systemItems: Int?) async -> AllowList {
        var apps = await first(of: RunningApps27().values()) ?? []
        let wasRunning = bundleIDs.map { apps.remove(AppID($0)) != nil }
        apps.insert(ownAppID)
        note("assertion hiding \(bundleIDs.joined(separator: ", ")): wasRunning=\(wasRunning) allowedBundleIDs=\(apps.count) systemItems=\(systemItems.map { "0...\($0)" } ?? "0...\(AllowListTranslation.allSystemItems.last ?? 0)")")
        return AllowList(apps: apps, keepsAllSystemItems: true)
    }

    private func prepare(_ list: AllowList, with backend: any ConcealmentBackend, label: String) async -> ConcealmentToken? {
        do {
            return try await backend.prepare(list)
        } catch {
            note("\(label): could not prepare the assertion", private: " (\(error))")
            return nil
        }
    }

    /// Activates, waiting at most `activationTimeout` on the injected clock for the completion.
    private func activate(_ token: ConcealmentToken, with backend: any ConcealmentBackend, label: String) async -> Activation {
        let start = ContinuousClock.now
        let clock = clock
        let timeout = Self.activationTimeout
        let outcome = await withTaskGroup(of: Activation?.self) { group in
            group.addTask {
                do {
                    try await backend.activate(token)
                    return .completed
                } catch {
                    return .failed("\(error)")
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return nil
                }
            }
            var first: Activation?
            for await result in group {
                if let result, first == nil {
                    first = result
                    group.cancelAll()
                }
            }
            return first ?? .timedOut
        }
        let latency = Self.milliseconds(ContinuousClock.now - start)
        switch outcome {
        case .completed: note("\(label): completion with no error, latencyMs=\(latency)")
        case .failed(let reason): note("\(label): activation failed, latencyMs=\(latency)", private: " (\(reason))")
        case .timedOut: note("\(label): no completion within \(Self.activationTimeout), continuing")
        }
        return outcome
    }

    /// `invalidate` on the backend only enqueues the framework call, so wait until it has run before logging it or
    /// letting the probe exit, for at most `drainTimeout`.
    private func invalidate(_ token: ConcealmentToken, with backend: any ConcealmentBackend, _ message: String) async {
        let start = ContinuousClock.now
        await backend.invalidate(token)
        if await drained(MenuBarAssertion.queue) {
            note("\(message), framework invalidate drained after \(Self.milliseconds(ContinuousClock.now - start)) ms")
        } else {
            note("\(message), but the framework queue did not drain within \(Self.drainTimeout), continuing")
        }
    }

    /// A barrier on `queue`: true once everything queued before the call has run, false when `drainTimeout` passes
    /// on the clock first. It never blocks the main actor, and a queue that is stuck can't hold the probe up.
    func drained(_ queue: DispatchQueue) async -> Bool {
        let clock = clock
        let timeout = Self.drainTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let outcome = OneShot(continuation)
            let timer = Task {
                guard (try? await clock.sleep(for: timeout)) != nil else { return }
                outcome.resume(with: false)
            }
            queue.async {
                if outcome.resume(with: true) { timer.cancel() }
            }
        }
    }

    // MARK: hide

    func hide(_ bundleID: String, maxSystemItem: Int?) async {
        let before = await scan(label: "scan before hide")
        logTarget(bundleID, in: before, label: "before hide")

        let backend = backend(maxSystemItem: maxSystemItem)
        guard let token = await prepare(await allowList(hiding: [bundleID], systemItems: maxSystemItem), with: backend, label: "hide") else { return }
        guard await activate(token, with: backend, label: "hide \(bundleID)").proceeds else {
            await backend.invalidate(token)
            return
        }

        let after = await scan(label: "scan while hidden")
        logTarget(bundleID, in: after, label: "while hidden")
        await panel.wait("\(bundleID) should be hidden now. Check the menu bar, then click Continue to invalidate the assertion.")
        await invalidate(token, with: backend, "hide: assertion invalidated")
        await panel.wait("Is \(bundleID)'s menu bar icon back now? Note the answer, then click Continue.")
    }

    // MARK: relist

    /// Open question: does an item created while its app was off the allowlist appear once a fresh
    /// allowlist includes it? Make-before-break from the first allowlist to the second.
    func relist(_ bundleID: String) async {
        let backend = backend(maxSystemItem: nil)
        let first = await allowList(hiding: [bundleID], systemItems: nil)
        guard let a = await prepare(first, with: backend, label: "relist") else { return }
        guard await activate(a, with: backend, label: "relist: hide \(bundleID)").proceeds else {
            await backend.invalidate(a)
            return
        }
        await panel.wait("\(bundleID) is hidden. Launch an app that is not running yet (for example Rectangle), wait until it has started, then click Continue.")

        let next = await allowList(hiding: [bundleID], systemItems: nil)
        let added = next.apps.subtracting(first.apps).map(\.bundleID).sorted()
        if added.isEmpty { note("relist: added none") }
        for id in added { note("relist: added \(id)") }
        guard let b = await prepare(next, with: backend, label: "relist") else {
            await backend.invalidate(a)
            return
        }
        guard await activate(b, with: backend, label: "relist: second allowlist").proceeds else {
            await backend.invalidate(a)
            await backend.invalidate(b)
            return
        }
        await invalidate(a, with: backend, "relist: first assertion invalidated")

        _ = await scan(label: "scan after relist")
        await panel.wait("Only the new allowlist is live. Is the new app's icon visible now? Note the answer, then click Continue.")
        await invalidate(b, with: backend, "relist: second assertion invalidated")
        await panel.wait("Is everything back? Click Continue.")
    }

    // MARK: hide-cancel

    /// Open question: is an invalidate that follows right behind an activation, before the agent confirms,
    /// effective? The backend gives no signal that the framework has been called, so the invalidate follows after
    /// `earlyInvalidateDelay` on the clock.
    func hideCancel(_ bundleID: String) async {
        let backend = backend(maxSystemItem: nil)
        guard let token = await prepare(await allowList(hiding: [bundleID], systemItems: nil), with: backend, label: "hide-cancel") else { return }
        let start = ContinuousClock.now
        let stamp: @Sendable () -> String = { String(format: "t=%.3fs", Double(Self.milliseconds(ContinuousClock.now - start)) / 1000) }

        let activation = Task { () -> Activation in
            do {
                try await backend.activate(token)
                return .completed
            } catch {
                return .failed("\(error)")
            }
        }
        note("hide-cancel: activate started \(stamp())")
        try? await clock.sleep(for: Self.earlyInvalidateDelay)
        await invalidate(token, with: backend, "hide-cancel: invalidate called \(stamp()), \(Self.earlyInvalidateDelay) after activate started")
        switch await activation.value {
        case .completed: note("hide-cancel: activation completed before the invalidate \(stamp())")
        case .failed(let reason): note("hide-cancel: activation ended \(stamp())", private: " (\(reason))")
        case .timedOut: note("hide-cancel: activation timed out \(stamp())")
        }

        let report = await scan(label: "scan after early invalidate")
        logTarget(bundleID, in: report, label: "after early invalidate")
        await panel.wait("Is \(bundleID)'s menu bar icon visible right now? Note the answer, then click Continue.")
        await invalidate(token, with: backend, "hide-cancel: final invalidate \(stamp())")
    }

    // MARK: swap

    func swap(_ first: String, _ second: String) async {
        let backend = backend(maxSystemItem: nil)
        let a = await prepare(await allowList(hiding: [first], systemItems: nil), with: backend, label: "swap")
        let b = await prepare(await allowList(hiding: [second], systemItems: nil), with: backend, label: "swap")
        guard let a, let b else {
            note("swap: could not create the assertions")
            if let a { await backend.invalidate(a) }
            if let b { await backend.invalidate(b) }
            return
        }
        guard await activate(a, with: backend, label: "swap: hide \(first)").proceeds else {
            await backend.invalidate(a)
            await backend.invalidate(b)
            return
        }
        await panel.wait("\(first) is hidden. Watch the menu bar closely, then click Continue to activate the second assertion (hiding \(second)) while the first is still live.")
        guard await activate(b, with: backend, label: "swap: hide \(second)").proceeds else {
            await backend.invalidate(a)
            await backend.invalidate(b)
            return
        }
        await panel.wait("Both assertions are live. What is hidden now? Click Continue to invalidate the first (\(first)).")
        await invalidate(a, with: backend, "swap: first assertion invalidated")
        await panel.wait("Only the second assertion is live. Is \(first) back and \(second) hidden, with no flash? Click Continue to invalidate the second.")
        await invalidate(b, with: backend, "swap: second assertion invalidated")
        await panel.wait("Are both icons back now? Note the answer, then click Continue.")
    }

    // MARK: crash

    func crash(_ bundleID: String) async {
        let backend = backend(maxSystemItem: nil)
        guard let token = await prepare(await allowList(hiding: [bundleID], systemItems: nil), with: backend, label: "crash") else {
            note("crash: could not create the assertion")
            return
        }
        guard await activate(token, with: backend, label: "crash: hide \(bundleID)").proceeds else { return }
        await panel.wait("\(bundleID) is hidden. Clicking Continue calls abort() on Hulder. Time how long the menu bar takes to show everything again.")
        note("crash: calling abort() now")
        abort()
    }
}
#endif
