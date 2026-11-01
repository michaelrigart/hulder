import HulderCore

public enum PlatformFactory {
    public static func make() -> any MenuBarPlatform {
        guard #available(macOS 27, *) else { return UnsupportedPlatform() }
        let core = MenuBarClientCore()
        if case .unavailable(let reason) = core.availability {
            return UnsupportedPlatform(reason: reason)
        }
        return Platform27(core: core)
    }
}
