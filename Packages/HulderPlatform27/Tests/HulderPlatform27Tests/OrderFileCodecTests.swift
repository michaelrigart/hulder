import Foundation
import HulderCore
import Testing
@testable import HulderPlatform27

private let codec = OrderFileCodec()
private let unsupported = OrderStoreError.unsupportedFormat("The menu bar order has a format Hulder doesn't know.")

private func keys(_ raws: String...) -> [ItemKey] {
    raws.map(ItemKey.init(raw:))
}

private func numbers(_ values: [String: Double]) -> [String: NSNumber] {
    values.mapValues { NSNumber(value: $0) }
}

private let a = "status:com.example.a::Item-0"
private let b = "status:com.example.b::Item-0"
private let c = "status:com.example.c::Item-0"
private let d = "status:com.example.d::Item-0"
private let clock = "module:Clock"

@Test func decodesRecordedFormat() throws {
    let positions: NSDictionary = [clock: 0, "module:BentoBox-0": 106, a: 233, b: 349]
    let order = try codec.decode(positions: positions)
    #expect(order.keys == keys(b, a, "module:BentoBox-0", clock))
    #expect(order.pinned == Set(keys(clock, "module:BentoBox-0")))
}

@Test func unknownFormatIsRejected() {
    #expect(throws: unsupported) { try codec.decode(positions: [clock, a] as NSArray) }
    #expect(throws: unsupported) { try codec.decode(positions: [clock: 0, a: "233"] as NSDictionary) }
}

@Test func onlyFiniteNumbersAreAccepted() {
    #expect(throws: unsupported) { try codec.decode(positions: [clock: 0, a: true] as NSDictionary) }
    #expect(throws: unsupported) { try codec.decode(positions: [clock: 0, a: Double.nan] as NSDictionary) }
    #expect(throws: unsupported) { try codec.decode(positions: [clock: 0, a: Double.infinity] as NSDictionary) }
}

@Test func decodesABackupFile() throws {
    let file = try PropertyListSerialization.data(
        fromPropertyList: ["TrailingItemPreferredPositions": [clock: 0, a: 233, b: 349.5]],
        format: .binary, options: 0
    )
    #expect(try codec.decode(file: file) == BarOrder(keys: keys(b, a, clock), pinned: [ItemKey(raw: clock)]))

    let withoutPositions = try PropertyListSerialization.data(fromPropertyList: ["Other": 1], format: .xml, options: 0)
    #expect(throws: unsupported) { try codec.decode(file: withoutPositions) }
    #expect(throws: unsupported) { try codec.decode(file: Data("not a property list".utf8)) }
}

@Test func applyingChangesOnlyMovedEntries() throws {
    let positions = numbers([clock: 0, a: 233, b: 349, c: 381, d: 417])
    let change = OrderChange(target: keys(d, c, a, b, clock), moved: keys(a))
    var expected = positions
    expected[a] = 365
    #expect(try codec.applying(change, to: positions) == expected)
}

@Test func applyingARun() throws {
    let positions = numbers([clock: 0, a: 20, b: 10, c: 100, d: 400])
    let change = OrderChange(target: keys(d, a, b, c, clock), moved: keys(a, b))
    var expected = positions
    expected[a] = 300
    expected[b] = 200
    #expect(try codec.applying(change, to: positions) == expected)
}

@Test func applyingAtTheLeftEnd() throws {
    let positions = numbers([clock: 0, a: 100, b: 300, c: 500])
    let change = OrderChange(target: keys(a, c, b, clock), moved: keys(a))
    var expected = positions
    expected[a] = 520
    #expect(try codec.applying(change, to: positions) == expected)
}

@Test func applyingAtTheRightEnd() throws {
    let positions = numbers([d: 300, a: 200, b: 100])
    let change = OrderChange(target: keys(d, b, a), moved: keys(a))
    var expected = positions
    expected[a] = 50
    #expect(try codec.applying(change, to: positions) == expected)
}

@Test func applyingWithNoNeighbours() throws {
    let positions = numbers([a: 5, b: 10])
    let change = OrderChange(target: keys(a, b), moved: keys(a, b))
    #expect(try codec.applying(change, to: positions) == numbers([a: 40, b: 20]))
}

@Test func aMissingMovedKeyIsAdded() throws {
    let positions = numbers([clock: 0, b: 300, c: 100])
    let change = OrderChange(target: keys(b, a, c, clock), moved: keys(a))
    #expect(try codec.applying(change, to: positions) == numbers([clock: 0, a: 200, b: 300, c: 100]))
}

@Test func unrepresentableTargetIsRejected() {
    let z = "status:com.example.z::Item-0"
    let positions = numbers([z: 200, a: 100, c: 100])
    let change = OrderChange(target: keys(a, z, c), moved: keys(z))
    #expect(throws: OrderStoreError.unrepresentable) { try codec.applying(change, to: positions) }
}

@Test func aTargetThatReordersUnmovedKeysIsRejected() {
    let positions = numbers([a: 300, b: 200, c: 100])
    let change = OrderChange(target: keys(b, a, c), moved: [])
    #expect(throws: OrderStoreError.unrepresentable) { try codec.applying(change, to: positions) }
}

/// A tie leaves the place to MenuBarAgent, whatever order the codec happens to decode it in.
@Test func aTieIsRejectedEvenWhenItDecodesAsTheTarget() {
    let positions = numbers([b: 200, a: 100, c: 100])
    let change = OrderChange(target: keys(a, b, c), moved: keys(b))
    #expect(throws: OrderStoreError.unrepresentable) { try codec.applying(change, to: positions) }
}

@Test func aLeftNeighbourAtZeroWithNoRightNeighbourIsRejected() {
    let positions = numbers([clock: 0, a: 100])
    let change = OrderChange(target: keys(clock, a), moved: keys(a))
    #expect(throws: OrderStoreError.unrepresentable) { try codec.applying(change, to: positions) }
}
