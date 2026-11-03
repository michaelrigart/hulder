import HulderCore

enum AllowListTranslation {
    /// macOS 27 keeps system items by index; the full range is `Array(0...127)`.
    static let allSystemItems = Array(0...127)

    static func arguments(for list: AllowList) -> (bundleIDs: [String], systemItems: [Int]) {
        let hidden = Set(list.hiddenSystemItems.compactMap(SystemItemTable27.number(for:)))
        return (list.apps.map(\.bundleID).sorted(), allSystemItems.filter { !hidden.contains($0) })
    }
}
