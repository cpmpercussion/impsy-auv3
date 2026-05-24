import UIKit
import AudioToolbox
import AVFoundation
import CoreAudioKit

// MARK: - HostViewController
//
// Container app. It does two things:
//
//  1. Loads IMPSYAudioUnit in-process and shows its UI — the working
//     development harness (iOS gives no loadInProcess for .appex files).
//
//  2. Probes the embedded IMPSYExtension-iOS.appex *out of process*, the
//     exact path AUM uses, and shows the result in a banner. This makes
//     extension-only failures (e.g. OSStatus -10875) visible on-device
//     without digging through Console logs.

final class HostViewController: UIViewController {

    private var audioUnit: IMPSYAudioUnit?
    private var midiBridge: CoreMIDIBridge?
    private let statusLabel = UILabel()
    private let probeBanner = UILabel()
    private var probeFinished = false

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
            statusLabel.removeFromSuperview()
            embed(viewController: vc)
            HostTestHooks.apply(to: au)
        } catch {
            statusLabel.text = "Failed to create IMPSY AU:\n\(error.localizedDescription)"
            print("[IMPSY] AU init failed: \(error)")
        }

        setupProbeBanner()
        probeOutOfProcess(desc: desc)
    }

    // MARK: - Out-of-process probe (reproduces the AUM path)

    private func probeOutOfProcess(desc: AudioComponentDescription) {
        // Fallback if the component is not registered / never calls back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.probeFinished else { return }
            self.setProbeResult("no response — extension not registered?", ok: false)
        }

        AVAudioUnit.instantiate(with: desc, options: []) { [weak self] avAudioUnit, error in
            guard let self else { return }
            if let error {
                NSLog("[IMPSY] probe: instantiate FAILED: %@", String(describing: error))
                self.setProbeResult("instantiate failed: \(error.localizedDescription)", ok: false)
                return
            }
            guard let au = avAudioUnit?.auAudioUnit else {
                self.setProbeResult("instantiate returned no audio unit", ok: false)
                return
            }
            // AVAudioUnit.instantiate with no options loads an AUv3 out of
            // process on iOS — the same path AUM uses.
            NSLog("[IMPSY] probe: instantiated out-of-process")
            do {
                try au.allocateRenderResources()
                au.deallocateRenderResources()
                NSLog("[IMPSY] probe: allocateRenderResources OK")
                self.setProbeResult("OK — extension loaded and initialised", ok: true)
            } catch {
                let code = (error as NSError).code
                NSLog("[IMPSY] probe: allocateRenderResources FAILED (%ld): %@",
                      code, String(describing: error))
                self.setProbeResult("loaded, init FAILED (OSStatus \(code))", ok: false)
            }
        }
    }

    private func setProbeResult(_ text: String, ok: Bool) {
        DispatchQueue.main.async {
            self.probeFinished = true
            self.probeBanner.text = "Extension probe: \(text)  ·  tap to dismiss"
            self.probeBanner.backgroundColor =
                (ok ? UIColor.systemGreen : UIColor.systemRed).withAlphaComponent(0.92)
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

    private func setupProbeBanner() {
        probeBanner.text = "Extension probe: running…"
        probeBanner.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        probeBanner.textColor = .white
        probeBanner.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.92)
        probeBanner.textAlignment = .center
        probeBanner.numberOfLines = 0
        probeBanner.isUserInteractionEnabled = true
        probeBanner.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(dismissBanner)))
        probeBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(probeBanner)
        NSLayoutConstraint.activate([
            probeBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            probeBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            probeBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    @objc private func dismissBanner() {
        probeBanner.isHidden = true
    }

    private func embed(viewController: UIViewController) {
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        // Added before the probe banner, so the banner stays on top.
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
