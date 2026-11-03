import Foundation

public struct HulderState: Codable, Equatable, Sendable {
    public var layout: Layout
    public var settings: HulderSettings

    public init(layout: Layout = Layout(), settings: HulderSettings = HulderSettings()) {
        self.layout = layout
        self.settings = settings
    }
}

public enum StateFileError: Error, Equatable {
    case unsupportedVersion(Int)
    case corrupt
}

public enum StateCodec {
    public static let currentVersion = 1

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let layout: Layout
        let settings: HulderSettings
    }

    public static func encode(_ state: HulderState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            Envelope(version: currentVersion, layout: state.layout, settings: state.settings))
    }

    public static func decode(_ data: Data) throws -> HulderState {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw StateFileError.corrupt
        }
        guard probe.version == currentVersion else {
            throw StateFileError.unsupportedVersion(probe.version)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw StateFileError.corrupt
        }
        return HulderState(layout: envelope.layout, settings: envelope.settings)
    }
}
