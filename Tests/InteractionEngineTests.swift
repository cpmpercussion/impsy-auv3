import XCTest
// Common sources are compiled directly into this test target (see project.yml)

final class InteractionEngineTests: XCTestCase {

    // MARK: - randomInitialSample
    //
    // Locks in parity with `random_sample` in ../impsy/impsy/mdrnn.py.
    // (issue #7: verify initialisation matches the IMPSY Python reference)

    func testRandomInitialSampleHasCorrectDimension() {
        XCTAssertEqual(InteractionEngine.randomInitialSample(dimension: 4).count, 4)
        XCTAssertEqual(InteractionEngine.randomInitialSample(dimension: 9).count, 9)
        XCTAssertTrue(InteractionEngine.randomInitialSample(dimension: 0).isEmpty)
    }

    func testRandomInitialSampleDtMatchesPythonRange() {
        // Python: output[0] = 0.01 + (rand - 0.5) * 0.005  →  dt ∈ (0.0075, 0.0125)
        for _ in 0..<200 {
            let sample = InteractionEngine.randomInitialSample(dimension: 4)
            XCTAssertGreaterThan(sample[0], 0.0075)
            XCTAssertLessThan(sample[0], 0.0125)
        }
    }

    func testRandomInitialSampleValuesInUnitInterval() {
        // Remaining dimensions must be in [0, 1), like Python's np.random.rand.
        for _ in 0..<50 {
            let sample = InteractionEngine.randomInitialSample(dimension: 6)
            for value in sample.dropFirst() {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThan(value, 1)
            }
        }
    }
}
