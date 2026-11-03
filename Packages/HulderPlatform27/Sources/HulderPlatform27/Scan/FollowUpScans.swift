import Foundation
import os

/// The later passes that follow an event. A launching app's menu bar item can appear after the scan the launch
/// triggered, and MenuBarAgent doesn't always announce it, so the bar is read again at fixed offsets from the change;
/// a pass that could not read the bar is tried once more soon after. One schedule is pending at a time and a new
/// event restarts it. Bounded and started by an event, so it is not polling.
final class FollowUpScans: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let sleep: Sleep = { try await Task.sleep(for: $0) }

    /// How long after a change in the running apps each follow-up pass is requested.
    static let offsets: [Duration] = [.seconds(1), .seconds(3), .seconds(10), .seconds(30)]

    private struct State {
        var generation = 0
        var stopped = false
        var task: Task<Void, Never>?
    }

    private let offsets: [Duration]
    private let sleep: Sleep
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(offsets: [Duration] = FollowUpScans.offsets, sleep: @escaping Sleep = FollowUpScans.sleep) {
        self.offsets = offsets
        self.sleep = sleep
    }

    /// Drops the pending schedule, if any, and calls `fire` at each offset from now.
    func restart(fire: @escaping @Sendable () -> Void) {
        state.withLock { state in
            guard !state.stopped else { return }
            state.generation += 1
            state.task?.cancel()
            let generation = state.generation
            let (offsets, sleep) = (offsets, sleep)
            state.task = Task { [state = self.state] in
                var elapsed = Duration.zero
                for offset in offsets {
                    do { try await sleep(offset - elapsed) } catch { return }
                    elapsed = offset
                    // Checked under the lock, so a schedule that a restart or the stop replaced never fires.
                    state.withLock { current in
                        if current.generation == generation, !current.stopped { fire() }
                    }
                }
            }
        }
    }

    /// Ends the pending schedule for good; later restarts do nothing.
    func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.stopped = true
            state.generation += 1
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
    }
}
