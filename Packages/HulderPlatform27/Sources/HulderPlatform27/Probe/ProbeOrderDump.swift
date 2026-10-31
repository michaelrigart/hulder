#if DEBUG
import Foundation

/// `order-dump`: what is under `~/Library/Group Containers/com.apple.MenuBar`, and what the
/// property lists in it contain.
enum ProbeOrderDump {
    private static let arrayEntryLimit = 200
    private static let depthLimit = 8

    static func run() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar")
        note("order-dump root: \(root.path)")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        note("root exists=\(exists) isDirectory=\(isDirectory.boolValue) readable=\(FileManager.default.isReadableFile(atPath: root.path))")

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: { url, error in
                let code = (error as NSError).code
                note("enumeration error at \(relative(url, to: root)) code=\(code)")
                PlatformLog.probe.notice("enumeration error detail: \(error.localizedDescription, privacy: .private)")
                return true
            }
        )
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            count += 1
            describe(url, root: root)
        }
        note("order-dump done: \(count) entries")
    }

    private static func describe(_ url: URL, root: URL) {
        let path = relative(url, to: root)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let accessFlag = FileManager.default.isReadableFile(atPath: url.path)
        let preferences = url.path.contains("/Library/Preferences/")
        if isDirectory {
            note("dir  \(path) isReadableFile=\(accessFlag)")
            return
        }

        let data: Data?
        var readCode = 0
        do { data = try Data(contentsOf: url) } catch {
            data = nil
            readCode = (error as NSError).code
            PlatformLog.probe.notice("read error detail: \(error.localizedDescription, privacy: .private)")
        }
        note("file \(path) size=\(values?.fileSize ?? -1) isReadableFile=\(accessFlag) readSucceeded=\(data != nil) readErrorCode=\(readCode) inPreferencesDomain=\(preferences)")
        guard let data else { return }

        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            note("  \(path) is a property list")
            dump(plist, label: "plist", depth: 0)
        } else if let json = try? JSONSerialization.jsonObject(with: data) {
            note("  \(path) is JSON")
            dump(json, label: "json", depth: 0)
        } else {
            note("  \(path) is neither a property list nor JSON; first bytes: \(hex(data.prefix(48)))")
        }
    }

    private static func dump(_ value: Any, label: String, depth: Int) {
        let indent = String(repeating: "  ", count: depth + 2)
        switch value {
        case let dictionary as [String: Any]:
            note("\(indent)\(label): dictionary(\(dictionary.count) keys)")
            guard depth < depthLimit else { return }
            for key in dictionary.keys.sorted() { dump(dictionary[key]!, label: key, depth: depth + 1) }
        case let array as [Any]:
            note("\(indent)\(label): array(\(array.count) entries)")
            guard depth < depthLimit else { return }
            for (index, element) in array.prefix(arrayEntryLimit).enumerated() {
                dump(element, label: "[\(index)]", depth: depth + 1)
            }
            if array.count > arrayEntryLimit { note("\(indent)  ... \(array.count - arrayEntryLimit) more entries not shown") }
        case let data as Data:
            note("\(indent)\(label): data(\(data.count) bytes) \(hex(data.prefix(32)))")
        case let date as Date:
            note("\(indent)\(label): date \(date)")
        case let string as String:
            note("\(indent)\(label): string \"\(string)\"")
        case let number as NSNumber:
            let kind = CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
            note("\(indent)\(label): \(kind) \(number)")
        default:
            note("\(indent)\(label): \(type(of: value)) \(value)")
        }
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.path
        return path.hasPrefix(root.path) ? "." + path.dropFirst(root.path.count) : path
    }
}
#endif
