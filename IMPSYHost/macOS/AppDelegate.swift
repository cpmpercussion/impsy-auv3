import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    private var windowController: HostWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = HostWindowController()
        wc.showWindow(nil)
        windowController = wc
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
