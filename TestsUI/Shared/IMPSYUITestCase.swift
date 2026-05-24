import XCTest

// MARK: - IMPSYUITestCase
//
// Shared base class for IMPSY UI tests. Provides:
//   - a configurable launch helper that honours every HostTestHooks env var
//   - dashboard / settings / mapping screen-switching
//   - a small set of common assertions (model ready, response state, …)
//
// Subclasses (iOS / macOS / cross-platform) build on these helpers so the
// individual test bodies stay focused on the behaviour they verify.

class IMPSYUITestCase: XCTestCase {

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    // MARK: - Launch

    /// Launches the host with the given launch-environment overrides applied.
    /// Each value here is plumbed into HostTestHooks on the host side.
    @discardableResult
    func launchHost(
        modelB64: String? = nil,
        modelPath: String? = nil,
        configB64: String? = nil,
        logFolder: URL? = nil,
        injectHz: Double? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if let modelB64 { app.launchEnvironment[UITestEnvKeys.modelB64] = modelB64 }
        if let modelPath { app.launchEnvironment[UITestEnvKeys.modelPath] = modelPath }
        if let configB64 { app.launchEnvironment[UITestEnvKeys.configB64] = configB64 }
        if let logFolder { app.launchEnvironment[UITestEnvKeys.logFolder] = logFolder.path }
        if let injectHz { app.launchEnvironment[UITestEnvKeys.injectHz] = String(injectHz) }
        app.launch()
        return app
    }

    // MARK: - Fixtures

    /// Loads a bundled fixture by `name.ext` from the UI test bundle.
    func fixtureData(name: String, ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: name, withExtension: ext),
            "Fixture \(name).\(ext) must be bundled with the UI test target"
        )
        return try Data(contentsOf: url)
    }

    /// Convenience: base64 of a bundled fixture.
    func fixtureBase64(name: String, ext: String) throws -> String {
        try fixtureData(name: name, ext: ext).base64EncodedString()
    }

    // MARK: - Screen navigation
    //
    // SwiftUI's segmented Picker creates a different control on iOS (UISegmentedControl
    // → buttons identified by their label text) vs macOS (NSSegmentedControl
    // → radio-like buttons). We've labelled the Picker `screenPicker` so the
    // segments are reachable via descendant `.buttons[<title>]` on both.

    enum Screen: String { case dashboard = "Dashboard", settings = "Settings", mapping = "Mapping" }

    func switchToScreen(_ screen: Screen, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["screenPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "screenPicker not found")

        // SwiftUI Picker(.segmented) becomes UISegmentedControl on iOS (segments
        // surface as `.buttons` keyed by title) and NSSegmentedControl on macOS
        // (segments surface as `.radioButtons` keyed by label).
        let title = screen.rawValue
        let candidates: [XCUIElement] = [
            picker.radioButtons[title],
            picker.buttons[title],
            app.radioButtons[title],
            app.buttons[title],
        ]
        if let hit = candidates.first(where: { $0.exists }) {
            hit.tap()
        } else {
            XCTFail("Could not find segment for \(title)")
        }
    }

    // MARK: - Common assertions

    /// Waits for the dashboard `Ready · dim:N …` line to appear. SwiftUI Text
    /// surfaces its content as `label` on iOS but `value` on macOS, so the
    /// predicate checks both.
    func waitForModelReady(dimension: Int, in app: XCUIApplication,
                           timeout: TimeInterval = 15) {
        let needle = "Ready · dim:\(dimension) "
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    needle, needle)
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected a static text containing '\(needle)…' on the dashboard."
        )
    }

    /// Waits for the dashboard CALL/RESPONSE badge to flip into RESPONSE — only
    /// happens once the engine is actively generating predictions from a live RNN.
    func waitForResponseState(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label == 'RESPONSE' OR value == 'RESPONSE'")
        let element = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected the dashboard to reach 'RESPONSE' state."
        )
    }

    /// Reads the textual content of a static-text element, regardless of which
    /// accessibility slot the platform uses for it. SwiftUI Text surfaces
    /// content as `label` on iOS and as `value` on macOS.
    static func staticTextContent(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        if let v = element.value as? String, !v.isEmpty { return v }
        return ""
    }

    /// Returns true when a toggle/checkbox-like element is on. iOS surfaces
    /// the state as `value as String "1"`; macOS uses an Int (1) for NSSwitch
    /// and NSButton checkboxes — `as? String` fails there, so accept either.
    static func toggleIsOn(_ element: XCUIElement) -> Bool {
        if let s = element.value as? String { return s == "1" }
        if let n = element.value as? Int { return n == 1 }
        if let n = element.value as? NSNumber { return n.intValue == 1 }
        return false
    }
}
