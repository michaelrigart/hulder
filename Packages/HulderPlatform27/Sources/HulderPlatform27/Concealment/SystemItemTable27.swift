import HulderCore

/// The modules macOS 27 lets Hulder hide: each one's menu extra identifier, system item number and module name in the
/// order file. The numbers were measured on macOS 27; a new macOS is checked with the probe's `hide-items`.
enum SystemItemTable27 {
    private struct Module {
        let identifier: String
        let orderName: String
        let number: Int
    }

    private static let modules = [
        Module(identifier: "com.apple.menuextra.battery", orderName: "Battery", number: 0),
        Module(identifier: "com.apple.menuextra.clock", orderName: "Clock", number: 2),
        Module(identifier: "com.apple.menuextra.sound", orderName: "Sound", number: 5),
        Module(identifier: "com.apple.menuextra.wifi", orderName: "WiFi", number: 6),
        Module(identifier: "com.apple.menuextra.controlcenter", orderName: "BentoBox", number: 8),
    ]

    /// The module a menu extra's identifier stands for, matched without regard to case; nil for any other.
    static func entry(forIdentifier identifier: String?) -> (id: SystemItemID, number: Int, orderName: String)? {
        guard let identifier = identifier?.lowercased(),
              let module = modules.first(where: { $0.identifier == identifier }) else { return nil }
        return (SystemItemID(moduleName: module.orderName), module.number, module.orderName)
    }

    /// The module names the order file uses, which `hide-items` takes.
    static var orderNames: [String] { modules.map(\.orderName) }

    static func number(for id: SystemItemID) -> Int? {
        modules.first { $0.orderName == id.moduleName }?.number
    }
}
