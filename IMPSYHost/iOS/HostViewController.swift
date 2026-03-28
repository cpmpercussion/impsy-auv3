import UIKit
import AVFoundation
import AudioToolbox
import CoreAudioKit

// MARK: - HostViewController
//
// Minimal host app that loads the IMPSY AUv3 extension and presents its UI.
// In normal use, IMPSY runs inside a proper MIDI host (AUM, etc.).
// This app just satisfies the App Store requirement for AUv3 container apps.

final class HostViewController: UIViewController {

    private var audioUnit: AUAudioUnit?
    private var auViewController: UIViewController?
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        loadAudioUnit()
    }

    private func setupUI() {
        statusLabel.text = "Loading IMPSY AUv3…"
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadAudioUnit() {
        let desc = AudioComponentDescription(
            componentType:         kAudioUnitType_MIDIProcessor,
            componentSubType:      fourCC("impy"),
            componentManufacturer: fourCC("CpM!"),
            componentFlags:        0,
            componentFlagsMask:    0
        )

        AUAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { [weak self] auAudioUnit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.statusLabel.text = "Failed to load AU: \(error.localizedDescription)"
                    return
                }
                guard let auAudioUnit else {
                    self.statusLabel.text = "Failed to load AU"
                    return
                }
                self.audioUnit = auAudioUnit
                auAudioUnit.requestViewController { [weak self] viewController in
                    guard let self, let vc = viewController else { return }
                    self.statusLabel.removeFromSuperview()
                    self.embed(viewController: vc)
                }
            }
        }
    }

    private func embed(viewController: UIViewController) {
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        viewController.didMove(toParent: self)
        auViewController = viewController
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
