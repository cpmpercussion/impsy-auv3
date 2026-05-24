import XCTest

// MARK: - HostRegressionTests
//
// Cross-platform regression suite for both host apps. Each test asserts a
// distinct end-to-end UI flow that we want to keep green between releases.
//
// What we deliberately *don't* cover here:
//   - File round-trip for TOML export and session-log writes. The host runs
//     sandboxed and the test runner can't read its container; the unit-test
//     suite already round-trips `IMPSYConfig.serialize` and `SessionLogger`
//     against real files, so these UI tests focus on whether the *UI*
//     reflects the right thing once those code paths fire.
//   - Real document-picker drives. HostTestHooks injects fixture data via
//     launch-env vars to sidestep the out-of-process pickers; the picker
//     buttons themselves are covered as "exists and tappable" only.

final class HostRegressionTests: IMPSYUITestCase {

    // MARK: - 1. Bundled model

    func testHostLaunchesWithBundledModel() {
        let app = launchHost()
        // The bundled default is the dim-9 MDRNN — see IMPSYAudioUnit+State.swift.
        waitForModelReady(dimension: 9, in: app)
        waitForResponseState(in: app)
    }

    // MARK: - 2. TOML import applies parameters

    func testImportTOMLAppliesParameters() throws {
        // Hand-built TOML with non-default values across every parameter the
        // import path touches. Each `apply()` call should push these into the
        // parameter tree, which the SwiftUI bindings mirror.
        let toml = """
        [interaction]
        threshold = 2.5
        input_thru = false

        [model]
        dimension = 9
        sigmatemp = 0.5
        pitemp = 2.0
        timescale = 0.5
        """
        let b64 = Data(toml.utf8).base64EncodedString()
        let app = launchHost(configB64: b64)

        // Wait until the bundled model is up before checking parameters, so
        // we know the deferred config-apply in HostTestHooks has fired.
        waitForModelReady(dimension: 9, in: app)
        switchToScreen(.settings, in: app)

        assertParameterValue("param.threshold.value", contains: "2.5", in: app)
        assertParameterValue("param.sigmaTemp.value", contains: "0.500", in: app)
        assertParameterValue("param.piTemp.value",    contains: "2.00",  in: app)
        assertParameterValue("param.timescale.value", contains: "0.50",  in: app)

        // The MIDI-Thru toggle should be off after import. SwiftUI Toggle
        // surfaces as a Switch on iOS but a CheckBox on macOS; the env-injected
        // config sets inputThru=false.
        let thru = app.descendants(matching: .any)["param.inputThru"]
        XCTAssertTrue(thru.waitForExistence(timeout: 3),
                      "param.inputThru toggle not found")
        XCTAssertFalse(IMPSYUITestCase.toggleIsOn(thru),
                       "Expected inputThru toggle to be off after TOML import.")
    }

    // MARK: - 3. Logging hookup

    func testLoggingFolderAndToggleAreApplied() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("impsy-ui-test-logs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let app = launchHost(logFolder: folder)
        waitForModelReady(dimension: 9, in: app)
        switchToScreen(.settings, in: app)

        // Toggle should reflect the env-driven "on" state.
        let toggle = app.descendants(matching: .any)["logging.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "logging.toggle not found")
        XCTAssertTrue(IMPSYUITestCase.toggleIsOn(toggle),
                      "Expected logging toggle to be ON after env hook.")

        // Folder path label should contain the chosen path's last segment.
        let folderLabel = app.staticTexts["logging.folderPath"]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 5),
                      "logging.folderPath not found")
        let content = IMPSYUITestCase.staticTextContent(folderLabel)
        XCTAssertTrue(content.contains(folder.lastPathComponent),
                      "Expected logging.folderPath to mention '\(folder.lastPathComponent)', got '\(content)'.")
    }

    // MARK: - 4. Screen switcher

    func testScreenSwitcherShowsAllThreeScreens() {
        let app = launchHost()
        waitForModelReady(dimension: 9, in: app)

        // Dashboard is the default screen.
        XCTAssertTrue(app.staticTexts["dashboard.callResponseState"]
                        .waitForExistence(timeout: 5),
                      "Dashboard not visible on launch")

        switchToScreen(.settings, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["param.threshold"]
                        .waitForExistence(timeout: 5),
                      "Settings → param.threshold not visible")
        XCTAssertTrue(app.buttons["config.importButton"].exists,
                      "Settings → Import TOML button missing")
        XCTAssertTrue(app.buttons["config.exportButton"].exists,
                      "Settings → Export TOML button missing")

        switchToScreen(.mapping, in: app)
        // The mapping screen contains its own Input/Output segmented control
        // (vs Dashboard's per-dim faders). Segment titles vary between iOS
        // UISegmentedControl and macOS NSSegmentedControl, so match against
        // either label or value.
        let inputPredicate = NSPredicate(format: "label == 'Input' OR value == 'Input'")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(inputPredicate).firstMatch
                .waitForExistence(timeout: 5),
            "Mapping screen Input segment not visible"
        )
        let outputPredicate = NSPredicate(format: "label == 'Output' OR value == 'Output'")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(outputPredicate).firstMatch.exists,
            "Mapping screen Output segment not visible"
        )

        switchToScreen(.dashboard, in: app)
        XCTAssertTrue(app.staticTexts["dashboard.callResponseState"]
                        .waitForExistence(timeout: 5),
                      "Dashboard tab did not return")
    }

    // MARK: - Helpers

    private func assertParameterValue(_ identifier: String,
                                      contains substring: String,
                                      in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 5),
                      "\(identifier) not found")
        let content = IMPSYUITestCase.staticTextContent(element)
        XCTAssertTrue(content.contains(substring),
                      "Expected \(identifier) to contain '\(substring)', got '\(content)'.")
    }
}
