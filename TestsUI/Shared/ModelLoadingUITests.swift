import XCTest

// MARK: - ModelLoadingUITests
//
// Regression tests for #9 ("Changing model doesn't seem to work") and the
// dimension-flex coverage in #10 ("Support for different dimension sizes").
// Each test launches the host with a non-bundled fixture model injected via
// `IMPSY_TEST_MODEL_B64`, then waits for the dashboard to show the matching
// `dim:N` status — confirming both that the load path doesn't silently fail
// (#9) and that the engine accepts dimensions other than the bundled default
// (#10).

final class ModelLoadingUITests: IMPSYUITestCase {

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

    func testNonBundledDim9ModelLoadsEndToEnd() throws {
        try assertModelLoads(
            fixtureName: "musicMDRNN-dim9-layers2-units64-mixtures5-scale10",
            expectedDimension: 9
        )
    }

    // Largest dimension we currently exercise — the IMPSY issue notes that
    // anything over 16 was untested in Python (see issue #10). Loading this
    // confirms the AUv3 can host wider models without falling over.
    //
    // The 1 MB tflite base64-encodes to ~1.3 MB which blows past the iOS
    // simulator's launch env-var size limit, so this case writes the fixture
    // to a temp file and passes the path via IMPSY_TEST_MODEL_PATH instead.
    func testNonBundledDim25ModelLoadsEndToEnd() throws {
        try assertModelLoads(
            fixtureName: "musicMDRNN-dim25-layers2-units128-mixtures5-scale10",
            expectedDimension: 25,
            viaFilePath: true
        )
    }

    private func assertModelLoads(fixtureName: String,
                                  expectedDimension: Int,
                                  viaFilePath: Bool = false) throws {
        let app: XCUIApplication
        if viaFilePath {
            let data = try fixtureData(name: fixtureName, ext: "tflite")
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("impsy-ui-test-\(fixtureName).tflite")
            try data.write(to: url)
            app = launchHost(modelPath: url.path)
        } else {
            let b64 = try fixtureBase64(name: fixtureName, ext: "tflite")
            app = launchHost(modelB64: b64)
        }

        // 1. Dashboard shows "Ready · dim:N …" via the dashboard.modelStatus
        //    identifier — confirms the load succeeded and inspector ran.
        waitForModelReady(dimension: expectedDimension, in: app)

        // 2. The model-status notification posts *before* the engine
        //    asynchronously builds the TFLiteRNN, so step 1 alone doesn't
        //    prove the engine actually loaded the model. Wait for the
        //    CALL → RESPONSE flip, which only happens once the engine has
        //    started generating predictions from a live RNN.
        waitForResponseState(in: app)
    }
}
