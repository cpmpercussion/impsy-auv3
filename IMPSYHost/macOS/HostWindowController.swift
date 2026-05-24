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

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IMPSY AUv3"
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
            window?.contentViewController = makeContentView(auViewController: vc)
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
    /// `addChild` is what keeps the AU view controller (and its view model)
    /// alive — without it the VC is released when `loadAudioUnit` returns and
    /// the viewModel.audioUnit binding (set on the main queue, post-dealloc)
    /// silently no-ops, leaving model loads stuck on "Loading...".
    private func makeContentView(auViewController: NSViewController) -> NSViewController {
        let container = NSViewController()
        let root = NSView()
        container.view = root
        container.addChild(auViewController)

        let auView = auViewController.view
        auView.translatesAutoresizingMaskIntoConstraints = false
        bridgeStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        bridgeStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bridgeStatusLabel.lineBreakMode = .byTruncatingTail
        bridgeStatusLabel.maximumNumberOfLines = 1

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
        return container
    }
}

private func fourCC(_ string: String) -> OSType {
    var result: OSType = 0
    for (i, char) in string.unicodeScalars.prefix(4).enumerated() {
        result |= OSType(char.value) << OSType((3 - i) * 8)
    }
    return result
}
