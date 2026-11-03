import Foundation
import HulderCore
import Synchronization
@testable import HulderPlatform27

/// A preferences backend for tests: what `copyPositions` returns, and the calls made.
final class FakePositionsBackend: PositionsBackend {
    enum Call: Equatable, Sendable {
        case copy
        case set
    }

    private struct State {
        var positions: [String: Double]?
        var unknownFormat = false
        var failsSets = false
        var onSet: (@Sendable () -> Void)?
        var log: [Call] = []
    }

    private let state: Mutex<State>
    private let gate = Gate()
    private let setGate = Gate()
    private let sets = Mutex(0)
    private let entered = Mutex(0)
    private let enteredContinuation: AsyncStream<Void>.Continuation
    let availability: Availability
    /// One element for every `copyPositions` call, yielded as the call starts, before it can block.
    let copyStarts: AsyncStream<Void>

    init(_ positions: [String: Double]?, availability: Availability = .available) {
        state = Mutex(State(positions: positions))
        self.availability = availability
        (copyStarts, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var log: [Call] { state.withLock { $0.log } }
    var positions: [String: Double]? { state.withLock { $0.positions } }

    func clearLog() {
        state.withLock { $0.log = [] }
    }

    /// Changes what the preferences hold, as a native drag would, without touching any file.
    func replace(with positions: [String: Double]?) {
        state.withLock { state in
            state.positions = positions
            state.unknownFormat = false
        }
    }

    func holdUnknownFormat() {
        state.withLock { $0.unknownFormat = true }
    }

    /// Every later `setPositions` saves nothing and returns false.
    func failSets() {
        state.withLock { $0.failsSets = true }
    }

    /// Runs inside every `setPositions`, before it saves.
    func onSet(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.onSet = action }
    }

    /// Every later `copyPositions` blocks its thread until `release`.
    func holdCopies() {
        gate.close()
    }

    /// Every later `setPositions` blocks its thread until `release`.
    func holdSets() {
        setGate.close()
    }

    /// Frees every blocked call and lets later ones through.
    func release() {
        gate.open()
        setGate.open()
    }

    /// How many `setPositions` calls have started, blocked ones included.
    var setCalls: Int { sets.withLock { $0 } }

    /// How many `copyPositions` calls have started, blocked ones included.
    var copyCalls: Int { entered.withLock { $0 } }

    func copyPositions() -> Any? {
        entered.withLock { $0 += 1 }
        enteredContinuation.yield()
        gate.wait()
        let (positions, unknownFormat) = state.withLock { state in
            state.log.append(.copy)
            return (state.positions, state.unknownFormat)
        }
        if unknownFormat { return ["not", "positions"] as NSArray }
        return positions.map { $0.mapValues { NSNumber(value: $0) } as NSDictionary }
    }

    func setPositions(_ positions: [String: NSNumber]) -> Bool {
        sets.withLock { $0 += 1 }
        setGate.wait()
        let values = positions.mapValues(\.doubleValue)
        let onSet = state.withLock { state in
            state.log.append(.set)
            return state.onSet
        }
        onSet?()
        return state.withLock { state in
            guard !state.failsSets else { return false }
            state.positions = values
            return true
        }
    }
}

/// Blocks callers of `wait` while closed.
private final class Gate: @unchecked Sendable { // reason: `isOpen` is only touched under `condition`
    private let condition = NSCondition()
    private var isOpen = true

    func close() {
        condition.withLock { isOpen = false }
    }

    func open() {
        condition.withLock { isOpen = true }
        condition.broadcast()
    }

    func wait() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }
}
