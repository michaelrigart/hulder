import Foundation

/// Where Hulder may hide anything from. macOS 27 attributes status items to an app, and gives it a
/// hiding assertion, only when its bundle sits directly in `/Applications`.
public enum InstallLocation {
    public static func isSupported(bundlePath: String) -> Bool {
        URL(fileURLWithPath: bundlePath).standardizedFileURL.deletingLastPathComponent().path == "/Applications"
    }
}
