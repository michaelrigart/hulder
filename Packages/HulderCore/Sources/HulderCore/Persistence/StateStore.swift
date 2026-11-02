import Foundation

public enum StateLoad: Equatable, Sendable {
    case fresh
    case loaded(HulderState)
    case recoveredFromCorrupt
    case refused(StateFileError)
}

public final class StateStore: Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.michaelrigart.hulder.state-store")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Blocks on the file: call it off the main actor.
    public func load() -> StateLoad {
        let data: Data
        do {
            guard let existing = try readExisting() else { return .fresh }
            data = existing
        } catch {
            return .refused(.corrupt)
        }
        do {
            return .loaded(try StateCodec.decode(data))
        } catch StateFileError.unsupportedVersion(let version) {
            return .refused(.unsupportedVersion(version))
        } catch {
            return moveCorruptAside()
        }
    }

    /// Saves on the store's own serial queue, so writes land in the order they are asked for and never block
    /// the caller's thread.
    public func write(_ state: HulderState) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try self.save(state) })
            }
        }
    }

    /// Blocks on the file; `write` is the call for app code.
    public func save(_ state: HulderState) throws {
        if let existing = try readExisting() {
            do {
                _ = try StateCodec.decode(existing)
            } catch StateFileError.unsupportedVersion(let version) {
                throw StateFileError.unsupportedVersion(version)
            } catch {
                throw StateFileError.corrupt
            }
        }
        let data = try StateCodec.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Nil only when opening the file fails with `ENOENT`. Any other failure, even one to find out whether the
    /// file exists, throws `corrupt`: a file that can't be told apart from a missing one must not be replaced.
    private func readExisting() throws -> Data? {
        let descriptor = open(fileURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StateFileError.corrupt
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw StateFileError.corrupt
        }
    }

    private func moveCorruptAside() -> StateLoad {
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("state.corrupt.json")
        // rename(2) replaces an older backup atomically, or fails and leaves both files.
        guard rename(fileURL.path, aside.path) == 0 else { return .refused(.corrupt) }
        return .recoveredFromCorrupt
    }
}
