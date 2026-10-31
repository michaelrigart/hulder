import AppKit
import HulderPlatform27

@main
final class HulderApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = HulderApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Hulder")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Hulder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        Log.app.notice("Hulder started")
        #if DEBUG
        if let probeArguments = PlatformProbe27.arguments(from: CommandLine.arguments) {
            Task { await PlatformProbe27.run(arguments: probeArguments) }
        }
        #endif
    }
}
