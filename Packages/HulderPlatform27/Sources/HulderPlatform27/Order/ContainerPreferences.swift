import Darwin
import Foundation
import HulderCore

/// Where the bar's order is read and written. Calls block: make them on one serial queue.
protocol PositionsBackend: Sendable {
    /// `.unavailable`, with a fixed reason, when this backend can't work on this system.
    var availability: Availability { get }
    /// The positions value as the preferences hold it now, or nil when there is none.
    func copyPositions() -> Any?
    /// Replaces the positions value. False when it could not be saved.
    func setPositions(_ positions: [String: NSNumber]) -> Bool
}

/// The Menu Bar preferences domain in its group container, through CoreFoundation's container-aware
/// preferences functions. They are private: each is looked up with `dlsym` at init, and when one is missing
/// nothing is called.
struct ContainerPreferences: PositionsBackend {
    typealias SymbolLookup = @Sendable (String) -> UnsafeMutableRawPointer?

    static let applicationID = "com.apple.MenuBar"
    static let copySymbol = "_CFPreferencesCopyAppValueWithContainer"
    static let setSymbol = "_CFPreferencesSetAppValueWithContainer"
    static let synchronizeSymbol = "_CFPreferencesAppSynchronizeWithContainer"

    /// `RTLD_DEFAULT`: every image already loaded, CoreFoundation among them.
    static let liveLookup: SymbolLookup = { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }

    // The copy returns a +1 reference.
    private typealias CopyFunction = @convention(c) (CFString, CFString, CFString) -> UnsafeRawPointer?
    private typealias SetFunction = @convention(c) (CFString, UnsafeRawPointer?, CFString, CFString) -> Void
    private typealias SynchronizeFunction = @convention(c) (CFString, CFString) -> UInt8

    private struct Functions: Sendable {
        let copy: CopyFunction
        let set: SetFunction
        let synchronize: SynchronizeFunction
    }

    let availability: Availability
    /// The folder's path as the probe passed it when the calls were measured: without a trailing slash.
    let containerPath: String
    private let functions: Functions?

    /// `container` is the group container folder itself.
    init(container: URL, lookup: SymbolLookup = liveLookup) {
        let path = container.path(percentEncoded: false)
        containerPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        switch Self.resolve(lookup) {
        case .success(let functions):
            self.functions = functions
            availability = .available
        case .failure(let missing):
            functions = nil
            availability = .unavailable("\(missing.symbol) missing")
        }
    }

    /// Synchronizes first, so the value is the one on disk rather than this process's cached copy.
    func copyPositions() -> Any? {
        guard let functions else { return nil }
        _ = functions.synchronize(Self.applicationID as CFString, containerPath as CFString)
        guard let raw = functions.copy(
            OrderFileCodec.positionsKey as CFString, Self.applicationID as CFString, containerPath as CFString
        ) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
    }

    /// Sets the value, then synchronizes; the result is the synchronize's.
    func setPositions(_ positions: [String: NSNumber]) -> Bool {
        guard let functions else { return false }
        let value = positions as NSDictionary
        withExtendedLifetime(value) {
            functions.set(
                OrderFileCodec.positionsKey as CFString, UnsafeRawPointer(Unmanaged.passUnretained(value).toOpaque()),
                Self.applicationID as CFString, containerPath as CFString
            )
        }
        return functions.synchronize(Self.applicationID as CFString, containerPath as CFString) != 0
    }

    private struct MissingSymbol: Error {
        let symbol: String
    }

    private static func resolve(_ lookup: SymbolLookup) -> Result<Functions, MissingSymbol> {
        guard let copy = lookup(copySymbol) else { return .failure(MissingSymbol(symbol: copySymbol)) }
        guard let set = lookup(setSymbol) else { return .failure(MissingSymbol(symbol: setSymbol)) }
        guard let synchronize = lookup(synchronizeSymbol) else { return .failure(MissingSymbol(symbol: synchronizeSymbol)) }
        return .success(Functions(
            copy: unsafeBitCast(copy, to: CopyFunction.self),
            set: unsafeBitCast(set, to: SetFunction.self),
            synchronize: unsafeBitCast(synchronize, to: SynchronizeFunction.self)
        ))
    }
}
