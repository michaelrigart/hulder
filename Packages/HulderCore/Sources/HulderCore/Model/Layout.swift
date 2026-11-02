import Foundation

public struct KnownApp: Codable, Equatable, Sendable {
    public var section: Section
    public var name: String
    public var lastSeen: Date

    public init(section: Section, name: String, lastSeen: Date) {
        self.section = section
        self.name = name
        self.lastSeen = lastSeen
    }
}

public struct Layout: Codable, Equatable, Sendable {
    public var defaultSection: Section = .visible
    public private(set) var apps: [AppID: KnownApp] = [:]

    public init() {}

    public func section(of app: AppID) -> Section? {
        apps[app]?.section
    }

    public func effectiveSection(of app: AppID) -> Section {
        section(of: app) ?? defaultSection
    }

    public mutating func assign(_ app: AppID, to section: Section) {
        apps[app]?.section = section
    }

    /// Returns true on a first sighting, which assigns `defaultSection`. For a known app, `lastSeen` changes
    /// only when the sighting is on another calendar day, so a scan alone doesn't change the layout.
    public mutating func recordSighting(_ app: AppID, name: String, at date: Date) -> Bool {
        if let known = apps[app] {
            apps[app]?.name = name
            if !Calendar.current.isDate(date, inSameDayAs: known.lastSeen) {
                apps[app]?.lastSeen = date
            }
            return false
        }
        apps[app] = KnownApp(section: defaultSection, name: name, lastSeen: date)
        return true
    }

    /// The apps that are new since `old`, or whose section changed, in bundle identifier order.
    public func assignments(since old: Layout) -> [(app: AppID, section: Section)] {
        apps
            .filter { app, known in old.apps[app]?.section != known.section }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.section) }
    }

    public mutating func forget(_ app: AppID) {
        apps[app] = nil
    }

    private enum CodingKeys: String, CodingKey {
        case defaultSection, apps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSection = try container.decode(Section.self, forKey: .defaultSection)
        let byBundleID = try container.decode([String: KnownApp].self, forKey: .apps)
        apps = Dictionary(uniqueKeysWithValues: byBundleID.map { (AppID($0.key), $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultSection, forKey: .defaultSection)
        let byBundleID = Dictionary(uniqueKeysWithValues: apps.map { ($0.key.bundleID, $0.value) })
        try container.encode(byBundleID, forKey: .apps)
    }
}
