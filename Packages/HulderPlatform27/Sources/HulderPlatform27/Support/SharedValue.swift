import os

/// One value shared with any number of subscribers: each gets the current value first, if there is one, then each change.
final class SharedValue<Value: Sendable & Equatable>: Sendable {
    private struct State {
        var value: Value?
        var finished = false
        var nextID = 0
        var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ initial: Value?) {
        state = OSAllocatedUnfairLock(initialState: State(value: initial))
    }

    var current: Value? { state.withLock { $0.value } }

    /// Stores `value`; when it differs from the current one, yields it to every subscriber and returns true.
    @discardableResult func set(_ value: Value) -> Bool {
        state.withLock { state in
            guard state.value != value else { return false }
            state.value = value
            for continuation in state.continuations.values { continuation.yield(value) }
            return true
        }
    }

    func values() -> AsyncStream<Value> {
        AsyncStream { continuation in
            // Registering and yielding the current value share one lock hold with `set`, so a change lands
            // either before the subscriber starts (and is its first value) or after (and is yielded to it).
            let id: Int? = state.withLock { state in
                if state.finished {
                    continuation.finish()
                    return nil
                }
                if let value = state.value { continuation.yield(value) }
                let id = state.nextID
                state.nextID += 1
                state.continuations[id] = continuation
                return id
            }
            guard let id else { return }
            continuation.onTermination = { [state] _ in
                _ = state.withLock { $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Ends every stream; later subscribers get a stream that has ended.
    func finish() {
        let ended = state.withLock { state in
            state.finished = true
            defer { state.continuations = [:] }
            return Array(state.continuations.values)
        }
        for continuation in ended { continuation.finish() }
    }
}
