import XCTest

// MARK: - ModelLoadingUITests
//
// Regression test for issue #9 ("Changing model doesn't seem to work") and
// the dimension-flex coverage in issue #10 ("Support for different dimension
// sizes"). Each test launches the iOS host with a non-bundled fixture model
// injected through the `IMPSY_TEST_MODEL_B64` launch-env hook, then waits
// for the dashboard to show the matching "dim:N" status — confirming both
// that the load path doesn't silently fail (#9) and that the engine accepts
// dimensions other than the bundled default (#10).

final class ModelLoadingUITests: XCTestCase {

    // MARK: - Tests

    func testNonBundledDim2ModelLoadsEndToEnd() throws {
        try assertModelLoads(
            fixtureName: "musicMDRNN-dim2-layers2-units32-mixtures5-scale10",
            expectedDimension: 2
        )
    }

    func testNonBundledDim4ModelLoadsEndToEnd() throws {
        try assertModelLoads(
            fixtureName: "musicMDRNN-dim4-layers2-units64-mixtures5-scale10",
            expectedDimension: 4
        )
    }

    // MARK: - Helper

    private func assertModelLoads(fixtureName: String, expectedDimension: Int) throws {
        let bundle = Bundle(for: type(of: self))
        let fixtureURL = try XCTUnwrap(
            bundle.url(forResource: fixtureName, withExtension: "tflite"),
            "Fixture \(fixtureName).tflite must be bundled with the UI test target"
        )
        let data = try Data(contentsOf: fixtureURL)
        let base64 = data.base64EncodedString()

        let app = XCUIApplication()
        app.launchEnvironment["IMPSY_TEST_MODEL_B64"] = base64
        app.launch()

        // 1. The dashboard renders model status as
        //    "Ready · dim:N layers:L units:U" (see ModelStatus.displayString).
        //    We assert the exact "dim:N " token (trailing space stops "dim:2"
        //    from accidentally matching "dim:24" etc.).
        let needle = "dim:\(expectedDimension) "
        let readyLabel = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", needle)
        ).firstMatch
        XCTAssertTrue(
            readyLabel.waitForExistence(timeout: 10),
            "Expected fixture to load and UI to show '\(needle)' status."
        )

        // 2. The model status notification posts *before* the engine
        //    asynchronously builds the TFLiteRNN, so step 1 alone doesn't
        //    prove the engine actually loaded the model. Wait for the
        //    CALL → RESPONSE flip, which only happens once the engine has
        //    started generating predictions from a live RNN. (The threshold
        //    parameter defaults to 0.1 s; with no user input the engine
        //    crosses to RESPONSE within a tick.)
        let responseLabel = app.staticTexts["RESPONSE"]
        XCTAssertTrue(
            responseLabel.waitForExistence(timeout: 10),
            "Expected engine to enter RESPONSE state for dim:\(expectedDimension)."
        )
    }
}
