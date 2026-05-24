import AppKit
import AudioToolbox
import CoreAudioKit

// MARK: - HostWindowController
//
// Container app for development on macOS. Instantiates IMPSYAudioUnit
// in-process (the AU sources are compiled into the host) and hosts its
// view controller in the main window. This sidesteps audiocomponentd
// registration, which is unreliable for development-installed builds.
//
// Also bridges the in-process AU's MIDI ring buffers to a pair of Core MIDI
// virtual endpoints ("IMPSY In" / "IMPSY Out"), so DAWs that don't host AUv3
// MIDI processors (e.g. Ableton Live) can still route MIDI through IMPSY.

final class HostWindowController: NSWindowController {

    private var audioUnit: IMPSYAudioUnit?
    private var midiBridge: CoreMIDIBridge?
    private let bridgeStatusLabel = NSTextField(labelWithString: "")
    // Strong reference: when we set `window.contentView` directly (instead of
    // `contentViewController`), the window does not retain the VC and its
    // SwiftUI view model would be deallocated mid-init.
    private var auViewController: NSViewController?

    convenience init() {
        // Default size fits the bundled 9D model's Dashboard and 8-row mapping
        // list without scrolling. The window is resizable so users with
        // smaller (or much larger) models can adapt — min/max are set on the
        // NSWindow rather than via a SwiftUI .frame() modifier, since the
        // SwiftUI route propagates through NSHostingController and pins the
        // content size, breaking interactive resize.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IMPSY"
        window.contentMinSize = NSSize(width: 380, height: 360)
        window.center()
        self.init(window: window)
        loadAudioUnit()
    }

    private func loadAudioUnit() {
        let desc = AudioComponentDescription(
            componentType:         kAudioUnitType_MIDIProcessor,
            componentSubType:      fourCC("impy"),
            componentManufacturer: fourCC("CpM!"),
            componentFlags:        0,
            componentFlagsMask:    0
        )

        do {
            let au = try IMPSYAudioUnit(componentDescription: desc, options: [])
            audioUnit = au

            // Exercise the real host lifecycle in-process (also starts the engine).
            do {
                try au.allocateRenderResources()
                NSLog("[IMPSY] host: in-process allocateRenderResources OK")
            } catch {
                NSLog("[IMPSY] host: in-process allocateRenderResources FAILED: %@",
                      String(describing: error))
            }

            startMIDIBridge(for: au)

            let vc = IMPSYViewController()
            vc.audioUnit = au
            auViewController = vc
            // Set the window's contentView directly rather than via
            // `contentViewController`. The VC route auto-binds the window's
            // content min/max to the VC's `preferredContentSize`, which —
            // combined with NSHostingController's own size propagation — pins
            // the window and prevents interactive resize. Going through
            // `contentView` keeps sizing entirely under our control.
            window?.contentView = makeContentView(auView: vc.view)
            if let w = window {
                w.contentMinSize = NSSize(width: 380, height: 360)
                // 660pt for the SwiftUI surface + 20pt for the bottom MIDI
                // bridge status label (sits inside the content area, not the
                // title bar).
                w.setContentSize(NSSize(width: 440, height: 680))
                w.center()
            }
            HostTestHooks.apply(to: au)
        } catch {
            window?.title = "IMPSY — Init error: \(error.localizedDescription)"
            NSLog("[IMPSY] AU init failed: %@", String(describing: error))
        }
    }

    // MARK: - Core MIDI bridge

    private func startMIDIBridge(for au: IMPSYAudioUnit) {
        let bridge = CoreMIDIBridge(engine: au.engine)
        bridge.start()
        midiBridge = bridge
        updateBridgeStatusLabel()
    }

    private func updateBridgeStatusLabel() {
        guard let bridge = midiBridge else {
            bridgeStatusLabel.stringValue = "MIDI Bridge: disabled"
            bridgeStatusLabel.textColor = .secondaryLabelColor
            return
        }
        if bridge.isRunning {
            bridgeStatusLabel.stringValue = "MIDI Bridge: ✓ virtual ports active (IMPSY In · IMPSY Out)"
            bridgeStatusLabel.textColor = .systemGreen
        } else {
            let detail = bridge.lastError.map { ": \($0)" } ?? ""
            bridgeStatusLabel.stringValue = "MIDI Bridge: ✗ failed\(detail)"
            bridgeStatusLabel.textColor = .systemRed
        }
    }

    /// Compose the AU's view with a bottom status strip showing bridge state.
    /// The caller is responsible for keeping the AU view controller alive —
    /// see `auViewController` on `HostWindowController`.
    private func makeContentView(auView: NSView) -> NSView {
        let root = NSView()
        auView.translatesAutoresizingMaskIntoConstraints = false
        bridgeStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        bridgeStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bridgeStatusLabel.lineBreakMode = .byTruncatingTail
        bridgeStatusLabel.maximumNumberOfLines = 1
        bridgeStatusLabel.setAccessibilityIdentifier("host.bridgeStatusLabel")

        root.addSubview(auView)
        root.addSubview(bridgeStatusLabel)

        NSLayoutConstraint.activate([
            auView.topAnchor.constraint(equalTo: root.topAnchor),
            auView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            auView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            auView.bottomAnchor.constraint(equalTo: bridgeStatusLabel.topAnchor, constant: -4),

            bridgeStatusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bridgeStatusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bridgeStatusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        return root
    }
}

private func fourCC(_ string: String) -> OSType {
    var result: OSType = 0
    for (i, char) in string.unicodeScalars.prefix(4).enumerated() {
        result |= OSType(char.value) << OSType((3 - i) * 8)
    }
    return result
}
