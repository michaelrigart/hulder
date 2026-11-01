import AppKit
import Darwin
import HulderCore

/// Who owns a process. An owner without a bundle identifier is named by its executable's file name, which is
/// what the order file uses; `proc_name` would truncate it to 16 characters.
enum OwnerResolver27 {
    static func owner(of app: NSRunningApplication) -> ItemOwner? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return .app(AppID(bundleID), name: app.localizedName ?? bundleID)
    }

    static func owner(of pid: pid_t) -> ItemOwner? {
        if let app = NSRunningApplication(processIdentifier: pid), let owner = owner(of: app) { return owner }
        return executableName(of: pid).map { .unresolved(processName: $0) }
    }

    static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return executableName(path: String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func executableName(path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }
}
