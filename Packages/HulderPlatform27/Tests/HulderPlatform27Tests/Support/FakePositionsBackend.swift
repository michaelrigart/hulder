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
    let availability: Availability

    init(_ positions: [String: Double]?, availability: Availability = .available) {
        state = Mutex(State(positions: positions))
        self.availability = availability
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

    /// Frees every blocked `copyPositions` and lets later ones through.
    func release() {
        gate.open()
    }

    func copyPositions() -> Any? {
        gate.wait()
        let (positions, unknownFormat) = state.withLock { state in
            state.log.append(.copy)
            return (state.positions, state.unknownFormat)
        }
        if unknownFormat { return ["not", "positions"] as NSArray }
        return positions.map { $0.mapValues { NSNumber(value: $0) } as NSDictionary }
    }

    func setPositions(_ positions: [String: NSNumber]) -> Bool {
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
private final class Gate: @unchecked Sendable {
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
