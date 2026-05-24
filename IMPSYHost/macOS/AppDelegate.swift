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
        installMainMenu()
        let wc = HostWindowController()
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Main menu
    //
    // Stand-in for the MainMenu.xib that AppKit apps normally load. Without
    // this NSApp.mainMenu stays nil, the menu bar is empty, and the standard
    // shortcuts (⌘Q, ⌘W, ⌘M, ⌘H, copy/paste, …) don't reach the responder
    // chain. We assemble just enough of the conventional layout — App / File
    // / Edit / Window — so the host behaves like a normal macOS app.

    private func installMainMenu() {
        let appName = "IMPSY"
        let mainMenu = NSMenu()

        // App menu — the title of the first item is replaced by AppKit with
        // CFBundleName at display time; the submenu's items are what matter.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // File menu — only Close, so ⌘W reaches the key window.
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")

        // Edit menu — text-field shortcuts for any embedded NSTextFields the
        // SwiftUI view tree puts on screen (model picker label, etc.).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo",
                                  action: Selector(("redo:")),
                                  keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        // Window menu — Minimize / Zoom / Bring All to Front. AppKit
        // populates a window list at the bottom automatically when
        // NSApp.windowsMenu is set.
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
