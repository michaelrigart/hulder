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
    public private(set) var systemItems: [SystemItemID: Section] = [:]

    public init() {}

    public func section(of app: AppID) -> Section? {
        apps[app]?.section
    }

    public func section(of item: SystemItemID) -> Section? {
        systemItems[item]
    }

    public mutating func assign(_ item: SystemItemID, to section: Section) {
        systemItems[item] = section
    }

    /// The section a unit counts as assigned to, for placing, Tidy, the misplaced marker and the concealment: the
    /// default section for an app the layout doesn't know yet, nil for an Apple item until the user assigns it, and
    /// always nil for MenuBarAgent and Control Center, which can't be assigned.
    public func assignedSection(of unit: AssignableUnit) -> Section? {
        switch unit {
        case .systemItem(let item): section(of: item)
        case .app(let app) where AppleOwners.assignable.contains(app): section(of: app)
        case .app(let app) where AppleOwners.all.contains(app): nil
        case .app(let app): section(of: app) ?? defaultSection
        }
    }

    /// The row a unit shows in: an Apple item the user hasn't assigned is in Visible.
    public func effectiveSection(of unit: AssignableUnit) -> Section {
        assignedSection(of: unit) ?? .visible
    }

    public func effectiveSection(of app: AppID) -> Section {
        effectiveSection(of: .app(app))
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

    /// The modules that are newly assigned since `old`, or whose section changed, in module name order.
    public func systemItemAssignments(since old: Layout) -> [(item: SystemItemID, section: Section)] {
        systemItems
            .filter { item, section in old.systemItems[item] != section }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    public mutating func forget(_ app: AppID) {
        apps[app] = nil
    }

    private enum CodingKeys: String, CodingKey {
        case defaultSection, apps, systemItems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSection = try container.decode(Section.self, forKey: .defaultSection)
        let byBundleID = try container.decode([String: KnownApp].self, forKey: .apps)
        apps = Dictionary(uniqueKeysWithValues: byBundleID.map { (AppID($0.key), $0.value) })
        let byModuleName = try container.decodeIfPresent([String: Section].self, forKey: .systemItems) ?? [:]
        systemItems = Dictionary(uniqueKeysWithValues: byModuleName.map { (SystemItemID(moduleName: $0.key), $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultSection, forKey: .defaultSection)
        let byBundleID = Dictionary(uniqueKeysWithValues: apps.map { ($0.key.bundleID, $0.value) })
        try container.encode(byBundleID, forKey: .apps)
        let byModuleName = Dictionary(uniqueKeysWithValues: systemItems.map { ($0.key.moduleName, $0.value) })
        try container.encode(byModuleName, forKey: .systemItems)
    }
}
