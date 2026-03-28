import AppKit
import AudioToolbox
import CoreAudioKit

final class HostWindowController: NSWindowController {

    private var audioUnit: AUAudioUnit?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
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

        AUAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { [weak self] auAudioUnit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.window?.title = "IMPSY — Load error: \(error.localizedDescription)"
                    return
                }
                guard let au = auAudioUnit else { return }
                self.audioUnit = au
                au.requestViewController { [weak self] viewController in
                    guard let self, let vc = viewController else { return }
                    self.window?.contentViewController = vc
                }
            }
        }
    }
}

private func fourCC(_ string: String) -> OSType {
    var result: OSType = 0
    for (i, char) in string.unicodeScalars.prefix(4).enumerated() {
        result |= OSType(char.value) << OSType((3 - i) * 8)
    }
    return result
}
