import XCTest

// MARK: - SessionPersistenceUITests
//
// The standalone hosts save their session (model, mappings, parameters) and
// restore it on the next launch — see HostSession in the host target. Each
// test sets a session up through the launch-env hooks, kills the app, and
// relaunches it with no hooks at all: whatever the second launch shows came
// from the saved session.
//
// The app is killed rather than quit, so what's restored is what autosave
// wrote — the same thing a crash mid-performance would leave behind.

final class SessionPersistenceUITests: IMPSYUITestCase {

    /// A test-only namespace, so runs never touch the user's real session.
    /// Each test's first launch resets it.
    private let sessionName = "ui-tests"

    /// Long enough for the config hook (applied 1 s after launch) and the
    /// 2 s autosave to have both happened.
    private func waitForAutosave() {
        Thread.sleep(forTimeInterval: 5)
    }

    func testLoadedModelSurvivesRelaunch() throws {
        let b64 = try fixtureBase64(name: "musicMDRNN-dim4-layers2-units64-mixtures5-scale10",
                                    ext: "tflite")
        let first = launchHost(modelB64: b64, session: sessionName, resetSession: true)
        waitForModelReady(dimension: 4, in: first)
        waitForAutosave()
        first.terminate()

        let second = launchHost(session: sessionName)
        waitForModelReady(dimension: 4, in: second)
        // The engine must actually be running the restored model.
        waitForResponseState(in: second)
    }

    func testParametersAndMappingsSurviveRelaunch() {
        // Three input mappings (the bundled model's default has eight) and
        // non-default values for every parameter.
        let toml = """
        [interaction]
        threshold = 2.5
        input_thru = false

        [model]
        dimension = 9
        sigmatemp = 0.5
        pitemp = 2.0
        timescale = 0.5

        [midi]
        input."Test" = [
          ["control_change", 5, 40],
          ["control_change", 5, 41],
          ["note_on", 6],
        ]
        output."Test" = [
          ["control_change", 5, 40],
          ["control_change", 5, 41],
          ["note_on", 6],
        ]
        """
        let first = launchHost(configB64: Data(toml.utf8).base64EncodedString(),
                               session: sessionName, resetSession: true)
        waitForModelReady(dimension: 9, in: first)
        // (The mapping screen isn't checked on this launch: the config hook
        // applies the TOML straight to the AU, bypassing the view model's
        // import path, so the UI still lists the old rows. The relaunch
        // below reads them back from the restored AU state.)
        waitForAutosave()
        first.terminate()

        let second = launchHost(session: sessionName)
        waitForModelReady(dimension: 9, in: second)

        switchToScreen(.settings, in: second)
        assertParameterValue("param.threshold.value", contains: "2.5",   in: second)
        assertParameterValue("param.sigmaTemp.value", contains: "0.500", in: second)
        assertParameterValue("param.piTemp.value",    contains: "2.00",  in: second)
        assertParameterValue("param.timescale.value", contains: "0.50",  in: second)
        let thru = second.descendants(matching: .any)["param.inputThru"]
        XCTAssertTrue(thru.waitForExistence(timeout: 3), "param.inputThru toggle not found")
        XCTAssertFalse(IMPSYUITestCase.toggleIsOn(thru),
                       "Expected MIDI Thru to still be off after relaunch.")

        // Mappings used with the bundled model were once replaced by the
        // defaults on restore; they must come back as saved.
        XCTAssertEqual(inputMappingRowCount(in: second), 3,
                       "Expected the three imported input mappings after relaunch.")
    }

    func testSessionIsOffByDefaultInTests() {
        // Guards the other UI suites: a plain launchHost() must not pick up
        // or leave behind a session.
        let app = launchHost()
        waitForModelReady(dimension: 9, in: app)
        XCTAssertEqual(inputMappingRowCount(in: app), 8)
    }

    // MARK: - Helpers

    private func inputMappingRowCount(in app: XCUIApplication) -> Int {
        switchToScreen(.mapping, in: app)
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'mapping.row.' AND identifier ENDSWITH '.enabled'"))
        _ = rows.firstMatch.waitForExistence(timeout: 5)
        return rows.count
    }

    private func assertParameterValue(_ identifier: String,
                                      contains substring: String,
                                      in app: XCUIApplication) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) not found")
        let content = IMPSYUITestCase.staticTextContent(element)
        XCTAssertTrue(content.contains(substring),
                      "Expected \(identifier) to contain '\(substring)', got '\(content)'.")
    }
}
