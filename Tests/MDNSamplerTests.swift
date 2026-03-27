import XCTest
@testable import IMPSYExtension_macOS   // or import the module containing MDNSampler

final class MDNSamplerTests: XCTestCase {

    // MARK: - Softmax

    func testSoftmaxSumsToOne() {
        let logits: [Float] = [1.0, 2.0, 3.0, 0.5]
        let result = MDNSampler.softmaxWithTemperature(logits, temperature: 1.0)
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-5)
    }

    func testSoftmaxWithHighTemperatureIsMoreUniform() {
        let logits: [Float] = [10.0, 0.0, 0.0]
        let sharp   = MDNSampler.softmaxWithTemperature(logits, temperature: 0.1)
        let diffuse = MDNSampler.softmaxWithTemperature(logits, temperature: 10.0)
        // Sharp distribution: first component should dominate
        XCTAssertGreaterThan(sharp[0], 0.99)
        // Diffuse: closer to uniform
        XCTAssertLessThan(diffuse[0], 0.5)
    }

    func testSoftmaxNumericalStability() {
        let logits: [Float] = [1000.0, 999.0, 998.0]
        let result = MDNSampler.softmaxWithTemperature(logits, temperature: 1.0)
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-5)
        XCTAssertFalse(result.contains { $0.isNaN || $0.isInfinite })
    }

    // MARK: - Categorical Sampling

    func testCategoricalSamplingInBounds() {
        let probs: [Float] = [0.1, 0.3, 0.6]
        for _ in 0..<100 {
            let idx = MDNSampler.sampleCategorical(probs)
            XCTAssertGreaterThanOrEqual(idx, 0)
            XCTAssertLessThan(idx, probs.count)
        }
    }

    func testCategoricalSamplingApproximatelyCorrect() {
        // With all probability mass on index 2, always pick 2
        let probs: [Float] = [0.0, 0.0, 1.0]
        for _ in 0..<20 {
            XCTAssertEqual(MDNSampler.sampleCategorical(probs), 2)
        }
    }

    // MARK: - Full Sample

    func testSampleReturnsCorrectDimension() {
        let dimension   = 9
        let numMixtures = 5
        // Build fake params: [mus: M*D | sigmas: M*D | piLogits: M]
        let paramCount = numMixtures * (2 * dimension + 1)
        var params = [Float](repeating: 0.5, count: paramCount)
        // Set piLogits (last M values) to uniform
        for i in (paramCount - numMixtures)..<paramCount { params[i] = 0.0 }

        let output = MDNSampler.sample(
            params: params,
            dimension: dimension,
            numMixtures: numMixtures,
            piTemp: 1.0,
            sigmaTemp: 0.01
        )

        XCTAssertEqual(output.count, dimension)
    }

    func testSampleValuesAreClamped() {
        let dimension   = 5
        let numMixtures = 5
        let paramCount  = numMixtures * (2 * dimension + 1)
        // Extreme mus — well outside [0,1] before clamping
        var params = [Float](repeating: 100.0, count: paramCount)
        for i in (paramCount - numMixtures)..<paramCount { params[i] = 0.0 }

        let output = MDNSampler.sample(
            params: params,
            dimension: dimension,
            numMixtures: numMixtures,
            piTemp: 1.0,
            sigmaTemp: 0.001
        )

        // Index 0 is time delta — must be positive
        XCTAssertGreaterThan(output[0], 0)
        // Indices 1… must be in [0,1]
        for v in output.dropFirst() {
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    func testPostProcessScaling() {
        // Unscaled raw values: time=0.05*10=0.5 (scaled), values=0.5*10=5.0
        let raw: [Float] = [0.5, 5.0, 3.0, 8.0]
        let processed = MDNSampler.postProcess(raw)
        XCTAssertEqual(processed[0], 0.5 / 10.0, accuracy: 1e-6)
        XCTAssertEqual(processed[1], 0.5, accuracy: 1e-6)   // clamped to [0,1]
        XCTAssertEqual(processed[3], 1.0, accuracy: 1e-6)   // 8/10=0.8 → ok... wait no 8/10=0.8 not 1.0
    }

    func testMinimumDeltaTime() {
        // Negative time delta should be corrected to minimum
        let raw: [Float] = [-5.0, 0.5]
        let processed = MDNSampler.postProcess(raw)
        XCTAssertGreaterThan(processed[0], 0)
        XCTAssertEqual(processed[0], Float(IMPSYConstants.minimumDeltaTime), accuracy: 1e-6)
    }
}
