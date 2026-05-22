import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: HostWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = HostWindowController()
        windowController = wc
        // Explicit activation + makeKeyAndOrderFront. Without these, an
        // @main NSApplicationDelegate without a storyboard/nib can launch
        // with a Dock icon and menu bar but no visible window.
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
