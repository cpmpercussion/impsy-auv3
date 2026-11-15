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

    // MARK: - silence()
    //
    // Hosts call silence() as they quit or are suspended. Every note the
    // engine started must get its note-off, and nothing may follow.

    func testSilenceReleasesEverySoundingNote() throws {
        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(
            forResource: "musicMDRNN-dim9-layers2-units64-mixtures5-scale10",
            withExtension: "tflite"))
        let modelData = try Data(contentsOf: url)
        let config = try ModelInspector.inspect(modelData: modelData)

        // Output dims 1, 3, 5, 7 are notes on channels 1–4.
        let engine = InteractionEngine(mappings: .aicU6MIDIProDefault())
        engine.dedupNoteWindowMs = 0
        engine.loadModel(modelData: modelData, displayName: "test", config: config)
        engine.start()

        // Let it cross the threshold and play; collect what it emits.
        var packets: [RawMIDIPacket] = []
        let deadline = Date().addingTimeInterval(10)
        var noteOns = 0
        while noteOns < 8, Date() < deadline {
            usleep(20_000)
            let batch = engine.outputBuffer.dequeueAll()
            noteOns += batch.filter { $0.bytes.0 & 0xF0 == 0x90 && $0.bytes.2 > 0 }.count
            packets += batch
        }
        XCTAssertGreaterThanOrEqual(noteOns, 8, "engine never started responding")

        engine.stop()
        engine.silence()
        packets += engine.outputBuffer.dequeueAll()

        var sounding = Set<UInt16>()   // channel << 8 | note
        for p in packets {
            let key = UInt16(p.bytes.0 & 0x0F) << 8 | UInt16(p.bytes.1)
            switch p.bytes.0 & 0xF0 {
            case 0x90 where p.bytes.2 > 0: sounding.insert(key)
            case 0x80, 0x90:               sounding.remove(key)
            default: break
            }
        }
        XCTAssertTrue(sounding.isEmpty, "notes left sounding after silence(): \(sounding)")
        XCTAssertEqual(engine.callResponseState, .call)

        // The cancelled response must not emit anything further.
        usleep(400_000)
        XCTAssertTrue(engine.outputBuffer.dequeueAll().isEmpty,
                      "engine kept emitting after stop() + silence()")
    }
}
