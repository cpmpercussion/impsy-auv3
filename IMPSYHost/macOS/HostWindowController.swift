import AppKit
import AudioToolbox
import CoreAudioKit

// MARK: - HostWindowController
//
// Container app for development on macOS. Instantiates IMPSYAudioUnit
// in-process (the AU sources are compiled into the host) and hosts its
// view controller in the main window. This sidesteps audiocomponentd
// registration, which is unreliable for development-installed builds.

final class HostWindowController: NSWindowController {

    private var audioUnit: IMPSYAudioUnit?

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

            let vc = IMPSYViewController()
            vc.audioUnit = au
            window?.contentViewController = vc
        } catch {
            window?.title = "IMPSY — Init error: \(error.localizedDescription)"
            NSLog("[IMPSY] AU init failed: %@", String(describing: error))
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
