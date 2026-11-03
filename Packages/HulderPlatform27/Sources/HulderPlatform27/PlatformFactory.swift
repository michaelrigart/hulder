import Foundation
import HulderCore

public enum PlatformFactory {
    public static func make() -> any MenuBarPlatform {
        let ownAppID = AppID(Bundle.main.bundleIdentifier ?? HulderCore.bundleID)
        guard #available(macOS 27, *) else {
            return UnsupportedPlatform(reason: UnsupportedPlatform.defaultReason, ownAppID: ownAppID)
        }
        let core = MenuBarClientCore()
        if case .unavailable(let reason) = core.availability {
            return UnsupportedPlatform(reason: reason, ownAppID: ownAppID)
        }
        return Platform27(core: core, ownAppID: ownAppID)
    }
}
