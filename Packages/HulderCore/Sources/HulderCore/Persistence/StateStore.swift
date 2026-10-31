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
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileManager.default.fileExists(atPath: fileURL.path) ? moveCorruptAside() : .fresh
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
        if let existing = try? Data(contentsOf: fileURL) {
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

    private func moveCorruptAside() -> StateLoad {
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("state.corrupt.json")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: aside)
        do {
            try fileManager.moveItem(at: fileURL, to: aside)
        } catch {
            return .refused(.corrupt)
        }
        return .recoveredFromCorrupt
    }
}
