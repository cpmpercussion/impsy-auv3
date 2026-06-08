import UIKit
import AudioToolbox
import CoreAudioKit

// MARK: - HostViewController
//
// Container app. Loads IMPSYAudioUnit in-process and shows its UI — the
// working development harness, since iOS gives no loadInProcess for .appex
// files — and bridges it to Core MIDI virtual ports.

final class HostViewController: UIViewController {

    private var audioUnit: IMPSYAudioUnit?
    private var midiBridge: CoreMIDIBridge?
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupStatusLabel()
        loadAudioUnit()
    }

    // MARK: - AU Loading

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

            // Expose this in-process AU as Core MIDI virtual ports so non-AUv3
            // hosts (or apps that don't host aumi) can drive IMPSY over MIDI.
            let bridge = CoreMIDIBridge(engine: au.engine)
            bridge.start()
            midiBridge = bridge

            let vc = IMPSYViewController()
            vc.audioUnit = au
            // Surface MIDI device pickers (#29) on the Settings screen.
            let store = MIDIEndpointStore()
            bridge.attach(store: store)
            vc.midiEndpointStore = store
            statusLabel.removeFromSuperview()
            embed(viewController: vc)
            HostTestHooks.apply(to: au)
        } catch {
            statusLabel.text = "Failed to create IMPSY AU:\n\(error.localizedDescription)"
            print("[IMPSY] AU init failed: \(error)")
        }
    }

    // MARK: - UI

    private func setupStatusLabel() {
        statusLabel.text = "Loading IMPSY AUv3…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func embed(viewController: UIViewController) {
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        // Pin to the full view (not the safe area): the SwiftUI ScrollView
        // insets its own content for the safe area, so the background fills
        // the screen edge-to-edge while controls stay clear of the notch.
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        viewController.didMove(toParent: self)
    }
}

// MARK: - FourCC Helper

private func fourCC(_ string: String) -> OSType {
    var result: OSType = 0
    for (i, char) in string.unicodeScalars.prefix(4).enumerated() {
        result |= OSType(char.value) << OSType((3 - i) * 8)
    }
    return result
}
