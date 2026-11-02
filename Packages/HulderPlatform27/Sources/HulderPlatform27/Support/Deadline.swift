import Synchronization

/// The first of a call's answer and its deadline.
///
/// The call runs unstructured and is never cancelled: the blocking work behind it ignores cancellation, so a
/// structured race would wait for the call itself. A call that answers after its deadline is abandoned, and its
/// value goes to `discard` so whatever it opened can be released.
enum Deadline {
    /// Hands the continuation to whoever asks first.
    private final class Waiter<T: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<T, any Error>?>

        init(_ continuation: CheckedContinuation<T, any Error>) {
            self.continuation = Mutex(continuation)
        }

        func take() -> CheckedContinuation<T, any Error>? {
            continuation.withLock { $0.take() }
        }
    }

    struct Expired: Error {}

    static func run<T: Sendable>(
        within timeout: Duration,
        _ call: @escaping @Sendable () async throws -> T,
        discarding discard: @escaping @Sendable (T) -> Void = { _ in }
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            let timer = Task.detached {
                do { try await Task.sleep(for: timeout) } catch { return }
                waiter.take()?.resume(throwing: Expired())
            }
            Task.detached {
                let result: Result<T, any Error>
                do { result = .success(try await call()) } catch { result = .failure(error) }
                timer.cancel()
                if let waiting = waiter.take() {
                    waiting.resume(with: result)
                } else if case .success(let late) = result {
                    discard(late)
                }
            }
        }
    }
}
