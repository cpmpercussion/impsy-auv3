import XCTest

// MARK: - MIDIConnectionUITests
//
// Smoke for the MIDI device pickers (#29). The standalone hosts attach a
// MIDIEndpointStore to the CoreMIDI bridge, which surfaces an Input and an
// Output device picker in the Settings screen's "MIDI Devices" section.
// (The AUv3 extension never gets a store, but these tests drive the hosts.)
//
// Device lists depend on what's attached to the test machine, so this only
// asserts the pickers exist — not their contents.

final class MIDIConnectionUITests: IMPSYUITestCase {

    func testSettingsShowsMIDIDevicePickers() {
        let app = launchHost()
        switchToScreen(.settings, in: app)

        // SwiftUI Picker(.menu) surfaces as a popUpButton on macOS and a
        // button on iOS — match by identifier across any element type.
        let inputPicker = app.descendants(matching: .any)["midi.inputPicker"]
        XCTAssertTrue(inputPicker.waitForExistence(timeout: 10),
                      "MIDI input device picker not found on Settings screen.")

        let outputPicker = app.descendants(matching: .any)["midi.outputPicker"]
        XCTAssertTrue(outputPicker.waitForExistence(timeout: 10),
                      "MIDI output device picker not found on Settings screen.")
    }
}
