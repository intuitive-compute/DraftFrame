import AppKit

final class DFAppDelegate: NSObject, NSApplicationDelegate {
    var windowController: DFWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let wc = DFWindowController()
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        windowController = wc
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
