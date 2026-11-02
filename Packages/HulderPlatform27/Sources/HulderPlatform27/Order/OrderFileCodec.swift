import Foundation
import HulderCore

/// Reads and edits `TrailingItemPreferredPositions`, the measured format of the bar's order: item key to points
/// from the bar's trailing edge, so a larger value sits further left. Pure.
struct OrderFileCodec: Sendable {
    static let positionsKey = "TrailingItemPreferredPositions"
    static let unsupportedFormatText = "The menu bar order has a format Hulder doesn't know."
    /// The clock and Control Center, which macOS keeps at the right end of the bar.
    static let pinnedKeys: Set<String> = ["module:Clock", "module:BentoBox-0"]
    /// The gap between moved items placed left of every other item.
    static let leftEndSpacing = 20.0

    private static let unsupported = OrderStoreError.unsupportedFormat(unsupportedFormatText)

    func decode(positions value: Any) throws(OrderStoreError) -> BarOrder {
        order(of: try positions(from: value))
    }

    /// A property list file holding the positions, such as a backup.
    func decode(file data: Data) throws(OrderStoreError) -> BarOrder {
        order(of: try positions(fromFile: data))
    }

    /// The positions, if `value` has the measured format: a dictionary of finite numbers.
    func positions(from value: Any) throws(OrderStoreError) -> [String: NSNumber] {
        guard let positions = value as? [String: NSNumber], positions.values.allSatisfy(Self.isFiniteNumber) else {
            throw Self.unsupported
        }
        return positions
    }

    func positions(fromFile data: Data) throws(OrderStoreError) -> [String: NSNumber] {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let value = plist?[Self.positionsKey] else { throw Self.unsupported }
        return try positions(from: value)
    }

    /// Left to right: descending value, then ascending key, the same order `ItemKeyBuilder` names items in.
    func order(of positions: [String: NSNumber]) -> BarOrder {
        let values = positions.mapValues(\.doubleValue)
        let keys = ItemKeyBuilder.leftToRight(values.keys, entries: values).map(ItemKey.init(raw:))
        let pinned = Self.pinnedKeys.filter { positions[$0] != nil }.map(ItemKey.init(raw:))
        return BarOrder(keys: keys, pinned: Set(pinned))
    }

    /// New values for the moved keys only. Each run of consecutive moved keys in the target is spread evenly
    /// between its nearest unmoved neighbours. Throws `unrepresentable` unless every moved key lands strictly
    /// between its neighbours and the result decodes to exactly the target: a tie would leave the place to
    /// MenuBarAgent.
    func applying(_ change: OrderChange, to positions: [String: NSNumber]) throws(OrderStoreError) -> [String: NSNumber] {
        let target = change.target.map(\.raw)
        let moved = Set(change.moved.map(\.raw))
        var result = positions
        var start = target.startIndex
        while start < target.endIndex {
            guard moved.contains(target[start]) else {
                start += 1
                continue
            }
            let end = target[start...].firstIndex { !moved.contains($0) } ?? target.endIndex
            let left = start > target.startIndex ? target[start - 1] : nil
            let right = end < target.endIndex ? target[end] : nil
            let values = try placements(count: end - start, left: left, right: right, in: positions)
            for (key, value) in zip(target[start..<end], values) { result[key] = NSNumber(value: value) }
            start = end
        }
        guard order(of: result).keys == change.target else { throw .unrepresentable }
        return result
    }

    /// `count` values, left to right, for a run between `left` and `right`. With no right neighbour the run
    /// ends at 0; with no left neighbour it steps `leftEndSpacing` apart from its right end.
    private func placements(
        count: Int, left: String?, right: String?, in positions: [String: NSNumber]
    ) throws(OrderStoreError) -> [Double] {
        let leftValue = try value(of: left, in: positions)
        let rightValue = try value(of: right, in: positions) ?? 0
        let values = (0..<count).map { index in
            let remaining = Double(count - index)
            guard let leftValue else { return rightValue + Self.leftEndSpacing * remaining }
            return rightValue + (leftValue - rightValue) * remaining / Double(count + 1)
        }
        let chain = (leftValue.map { [$0] } ?? []) + values + (right == nil ? [] : [rightValue])
        guard zip(chain, chain.dropFirst()).allSatisfy({ $0 > $1 }) else { throw .unrepresentable }
        return values
    }

    /// Nil when there is no neighbour; an unmoved neighbour with no value can't anchor a run.
    private func value(of key: String?, in positions: [String: NSNumber]) throws(OrderStoreError) -> Double? {
        guard let key else { return nil }
        guard let value = positions[key] else { throw .unrepresentable }
        return value.doubleValue
    }

    private static func isFiniteNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }
}
