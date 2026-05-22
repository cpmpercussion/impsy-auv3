import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    // The default `static main()` that NSApplicationDelegate provides just
    // calls NSApplicationMain, which looks to a main nib/storyboard to wire
    // up the delegate — we have neither, so it never gets set and our
    // applicationDidFinishLaunching is never invoked. Override main() to
    // install the delegate ourselves before running the event loop.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var windowController: HostWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[IMPSY] AppDelegate.applicationDidFinishLaunching")
        let wc = HostWindowController()
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
