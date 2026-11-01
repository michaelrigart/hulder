import HulderCore

enum AllowListTranslation {
    /// macOS 27 keeps system items by index; the full range is `Array(0...127)`.
    static let allSystemItems = Array(0...127)

    static func arguments(for list: AllowList) -> (bundleIDs: [String], systemItems: [Int]) {
        (list.apps.map(\.bundleID).sorted(), list.keepsAllSystemItems ? allSystemItems : [])
    }
}
