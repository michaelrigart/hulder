import Foundation

public struct AppID: Hashable, Comparable, Codable, Sendable {
    public let bundleID: String

    public init(_ bundleID: String) {
        self.bundleID = bundleID
    }

    public init(from decoder: any Decoder) throws {
        bundleID = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bundleID)
    }

    public static func < (lhs: AppID, rhs: AppID) -> Bool {
        lhs.bundleID < rhs.bundleID
    }
}
