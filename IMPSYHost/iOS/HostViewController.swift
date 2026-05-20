import UIKit
import AudioToolbox
import CoreAudioKit

// MARK: - HostViewController
//
// Container app that loads IMPSY directly in-process.
//
// iOS does not provide loadInProcess for AUv3, and bundle.load() is
// rejected for .appex files. auriserver registration is asynchronous
// and unreliable in development. Compiling IMPSYAudioUnit into the
// host target and instantiating it directly is the correct solution.
//
// The embedded IMPSYExtension-iOS.appex is still present for external
// MIDI hosts (AUM, etc.) to use once auriserver registers it.

final class HostViewController: UIViewController {

    private var audioUnit: IMPSYAudioUnit?
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

            // A real host (AUM) starts the engine via allocateRenderResources()
            // when it wires the AU into its audio graph. This test host has no
            // audio graph, so start the call-and-response loop directly.
            au.engine.start()

            let vc = IMPSYViewController()
            vc.audioUnit = au
            statusLabel.removeFromSuperview()
            embed(viewController: vc)
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
