import AppKit
import HulderPlatform27

@main
final class HulderApp: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var probeStatusItem: NSStatusItem?
    #endif
    private var composition: AppComposition?
    private var isTerminating = false

    static func main() {
        let app = NSApplication.shared
        let delegate = HulderApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Hulder started")
        #if DEBUG
        if let probeArguments = PlatformProbe27.arguments(from: CommandLine.arguments) {
            installProbeStatusItem()
            Task { await PlatformProbe27.run(arguments: probeArguments) }
            return
        }
        #endif
        Task {
            // The factory loads a private framework and the state file is read from disk: both run off the
            // main actor.
            let store = AppComposition.makeStateStore()
            let (platform, load) = await Task.detached { (PlatformFactory.make(), store.load()) }.value
            let composition = AppComposition(platform: platform, store: store, load: load)
            self.composition = composition
            composition.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let composition else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await composition.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    #if DEBUG
    private func installProbeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Hulder")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Hulder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        probeStatusItem = item
    }
    #endif
}
