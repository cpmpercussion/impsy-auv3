import XCTest
// Common sources are compiled directly into this test target (see project.yml)

final class ModelInspectorTests: XCTestCase {

    // MARK: - Live model test (requires a .tflite file)
    //
    // To run this test, copy a model from ../impsy/models/ and update the path below.
    // This test is skipped if the model file does not exist.

    func testInspectRealModel() throws {
        let modelURL = URL(fileURLWithPath: "../impsy/models/musicMDRNN-dim9-layers2-units64-mixtures5-scale10.tflite")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Model file not found at \(modelURL.path)")
        }

        let config = try ModelInspector.inspect(modelURL: modelURL)
        XCTAssertEqual(config.dimension, 9)
        XCTAssertEqual(config.numLayers, 2)
        XCTAssertEqual(config.hiddenUnits, 64)
        XCTAssertEqual(config.numMixtures, 5)
    }

    func testInspectSmallModel() throws {
        let candidates = [
            "../impsy/models/musicMDRNN-dim2-layers2-units64-mixtures5-scale10.tflite",
            "../impsy/models/musicMDRNN-dim4-layers2-units64-mixtures5-scale10.tflite",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("No small model found")
        }
        let config = try ModelInspector.inspect(modelURL: URL(fileURLWithPath: path))
        XCTAssertGreaterThanOrEqual(config.dimension, 2)
        XCTAssertGreaterThanOrEqual(config.numLayers, 1)
        XCTAssertGreaterThan(config.hiddenUnits, 0)
        XCTAssertGreaterThan(config.numMixtures, 0)
    }

    // MARK: - Bundled-fixture test
    //
    // Inspects a .tflite shipped with the test target. This exercises the
    // full TFLite path on macOS (interpreter create → allocateTensors →
    // warmup invoke → tensor name/shape readback) using only resources in
    // the test bundle, so it runs in CI without depending on the sibling
    // IMPSY repo.
    func testInspectBundledSmallModel() throws {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(
            forResource: "musicMDRNN-dim4-layers2-units64-mixtures5-scale10",
            withExtension: "tflite"
        ) else {
            throw XCTSkip("Bundled fixture not found in test target")
        }
        let config = try ModelInspector.inspect(modelURL: url)
        XCTAssertEqual(config.dimension, 4)
        XCTAssertEqual(config.numLayers, 2)
        XCTAssertEqual(config.hiddenUnits, 64)
        XCTAssertEqual(config.numMixtures, 5)
    }

    // MARK: - Error cases

    func testInspectNonExistentFileThrows() {
        let url = URL(fileURLWithPath: "/tmp/doesnotexist.tflite")
        XCTAssertThrowsError(try ModelInspector.inspect(modelURL: url))
    }
}
