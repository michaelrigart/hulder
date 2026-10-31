import Foundation

public enum StateLoad: Equatable, Sendable {
    case fresh
    case loaded(HulderState)
    case recoveredFromCorrupt
    case refused(StateFileError)
}

public final class StateStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

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

    /// Nil when there is no file; throws `corrupt` when a file exists but can't be read.
    private func readExisting() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
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
