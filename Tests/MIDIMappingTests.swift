import XCTest
// Common sources are compiled directly into this test target (see project.yml)

final class MIDIMappingTests: XCTestCase {

    // MARK: - MIDIMappingSet defaults

    func testDefaultsCreatesCorrectCount() {
        let mappings = MIDIMappingSet.defaults(forModelDimension: 9)
        XCTAssertEqual(mappings.inputMappings.count, 8)
        XCTAssertEqual(mappings.outputMappings.count, 8)
    }

    func testResizeGrowsAndShrinks() {
        var mappings = MIDIMappingSet.defaults(forModelDimension: 5)
        XCTAssertEqual(mappings.inputMappings.count, 4)

        mappings.resize(toModelDimension: 9)
        XCTAssertEqual(mappings.inputMappings.count, 8)

        mappings.resize(toModelDimension: 3)
        XCTAssertEqual(mappings.inputMappings.count, 2)
    }

    // MARK: - MIDIMapper decode

    func testDecodeNoteOn() {
        let mappings = MIDIMappingSet(
            inputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 60)],
            outputMappings: []
        )
        let mapper = MIDIMapper(mappings: mappings)
        // Note On ch1, note 60, velocity 100
        let bytes: [UInt8] = [0x90, 60, 100]
        let result = bytes.withUnsafeBufferPointer { buf in
            mapper.denseUpdate(fromBytes: buf.baseAddress!, length: 3)
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, 0)   // 0-based index for dim 1
        XCTAssertEqual(result?.1 ?? -1, 100.0 / 127.0, accuracy: 1e-4)
    }

    func testDecodeCC() {
        let mappings = MIDIMappingSet(
            inputMappings: [DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74)],
            outputMappings: []
        )
        let mapper = MIDIMapper(mappings: mappings)
        let bytes: [UInt8] = [0xB0, 74, 64]
        let result = bytes.withUnsafeBufferPointer { buf in
            mapper.denseUpdate(fromBytes: buf.baseAddress!, length: 3)
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1 ?? -1, 64.0 / 127.0, accuracy: 1e-4)
    }

    func testDecodePitchBend() {
        let mappings = MIDIMappingSet(
            inputMappings: [DimensionMapping(id: 1, messageType: .pitchBend, channel: 1, number: 0)],
            outputMappings: []
        )
        let mapper = MIDIMapper(mappings: mappings)
        // Pitch bend centre = 0x2000 = 8192; LSB=0, MSB=64 → (64<<7)|0 = 8192
        let bytes: [UInt8] = [0xE0, 0, 64]
        let result = bytes.withUnsafeBufferPointer { buf in
            mapper.denseUpdate(fromBytes: buf.baseAddress!, length: 3)
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1 ?? -1, 8192.0 / 16383.0, accuracy: 1e-4)
    }

    func testDecodeNoMatchReturnsNil() {
        let mappings = MIDIMappingSet(
            inputMappings: [DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74)],
            outputMappings: []
        )
        let mapper = MIDIMapper(mappings: mappings)
        // CC on channel 2 — should not match
        let bytes: [UInt8] = [0xB1, 74, 64]
        let result = bytes.withUnsafeBufferPointer { buf in
            mapper.denseUpdate(fromBytes: buf.baseAddress!, length: 3)
        }
        XCTAssertNil(result)
    }

    // MARK: - MIDIMapper encode

    func testEncodeCC() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [0.5])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].statusByte, 0xB0)
        XCTAssertEqual(events[0].data1, 74)
        XCTAssertEqual(events[0].data2, 64)   // 0.5 * 127 = 63.5 → 64
    }

    func testEncodeClamps() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 1)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [1.5])   // out of range
        XCTAssertEqual(events[0].data2, 127)
    }

    // MARK: - Monophonic note_off insertion

    func testFirstNoteOnEmitsNoNoteOff() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [60.0 / 127.0])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].statusByte, 0x90)
        XCTAssertEqual(events[0].data1, 60)
    }

    func testSubsequentNoteOnPrependsNoteOffForPrevious() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0])
        let events = mapper.encodeOutput(values: [72.0 / 127.0])
        XCTAssertEqual(events.count, 2)
        // First: note_off for the previous note (60), velocity 0.
        XCTAssertEqual(events[0].statusByte, 0x80)
        XCTAssertEqual(events[0].data1, 60)
        XCTAssertEqual(events[0].data2, 0)
        // Then: note_on for the new note (72).
        XCTAssertEqual(events[1].statusByte, 0x90)
        XCTAssertEqual(events[1].data1, 72)
    }

    func testRepeatedNoteReArticulates() {
        // Matches IMPSY Python: a repeated note_on still gets a preceding
        // note_off so the synth re-articulates rather than ignoring it.
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0])
        let events = mapper.encodeOutput(values: [60.0 / 127.0])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].statusByte, 0x80)
        XCTAssertEqual(events[0].data1, 60)
        XCTAssertEqual(events[1].statusByte, 0x90)
        XCTAssertEqual(events[1].data1, 60)
    }

    func testNoteOffsAreIndependentPerChannel() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [
                DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0),
                DimensionMapping(id: 2, messageType: .noteOn, channel: 2, number: 0),
            ]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0, 64.0 / 127.0])
        let events = mapper.encodeOutput(values: [72.0 / 127.0, 64.0 / 127.0])
        // Each channel re-articulates: 4 events total (off+on, off+on).
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].statusByte, 0x80)      // ch1 off prev
        XCTAssertEqual(events[0].data1, 60)
        XCTAssertEqual(events[1].statusByte, 0x90)      // ch1 on new
        XCTAssertEqual(events[1].data1, 72)
        XCTAssertEqual(events[2].statusByte, 0x81)      // ch2 off prev
        XCTAssertEqual(events[2].data1, 64)
        XCTAssertEqual(events[3].statusByte, 0x91)      // ch2 on new
        XCTAssertEqual(events[3].data1, 64)
    }

    func testCCDoesNotEmitNoteOff() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [0.25])
        let events = mapper.encodeOutput(values: [0.75])
        // Just the second CC value — no note_off side-effects from CC outputs.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].statusByte, 0xB0)
    }

    func testReleaseAllNotesProducesOffForEachHeldNote() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [
                DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0),
                DimensionMapping(id: 2, messageType: .noteOn, channel: 4, number: 0),
            ]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0, 67.0 / 127.0])

        let offs = mapper.releaseAllNotes()
        XCTAssertEqual(offs.count, 2)
        let pairs = Set(offs.map { [$0.statusByte, $0.data1] })
        XCTAssertEqual(pairs, Set([[0x80, 60], [0x83, 67]]))

        // Subsequent release without intervening note_on returns nothing.
        XCTAssertTrue(mapper.releaseAllNotes().isEmpty)

        // And the next note_on on a tracked channel emits no leading note_off,
        // since state was cleared.
        let next = mapper.encodeOutput(values: [72.0 / 127.0, 0])
        XCTAssertEqual(next.first?.statusByte, 0x90)
        XCTAssertEqual(next.first?.data1, 72)
    }

    // MARK: - Codable round-trip

    func testMappingSetRoundTrips() throws {
        let original = MIDIMappingSet.defaults(forModelDimension: 5)
        let data      = try JSONEncoder().encode(original.inputMappings)
        let decoded   = try JSONDecoder().decode([DimensionMapping].self, from: data)
        XCTAssertEqual(decoded, original.inputMappings)
    }

    // MARK: - Disabled dimensions (issue #24)

    func testDisabledOutputDimensionEmitsNothing() {
        var disabled = DimensionMapping(id: 1, messageType: .controlChange,
                                        channel: 1, number: 74)
        disabled.enabled = false
        let enabled = DimensionMapping(id: 2, messageType: .controlChange,
                                       channel: 1, number: 75)
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [disabled, enabled]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [0.5, 0.5])
        // Only the enabled dim emits — disabled dim is silent.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data1, 75)
    }

    func testDisabledInputDimensionIgnoresMatchingMIDI() {
        var disabled = DimensionMapping(id: 1, messageType: .controlChange,
                                        channel: 1, number: 74)
        disabled.enabled = false
        let mappings = MIDIMappingSet(
            inputMappings: [disabled],
            outputMappings: []
        )
        let mapper = MIDIMapper(mappings: mappings)
        let bytes: [UInt8] = [0xB0, 74, 64]
        let result = bytes.withUnsafeBufferPointer { buf in
            mapper.denseUpdate(fromBytes: buf.baseAddress!, length: 3)
        }
        XCTAssertNil(result)
    }

    func testEnabledDefaultsTrue() {
        let m = DimensionMapping.defaults(forDimension: 1)
        XCTAssertTrue(m.enabled)
    }

    func testEnabledDecodesMissingAsTrue() throws {
        // Mappings persisted before #24 don't carry an `enabled` key. The
        // custom decoder must default missing → enabled so existing fullState
        // dictionaries don't silently disable every dimension on restore.
        let legacyJSON = """
        {"id":1,"messageType":"controlChange","channel":1,"number":74,
         "minValue":0,"maxValue":127}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DimensionMapping.self, from: legacyJSON)
        XCTAssertTrue(decoded.enabled)
    }

    func testEnabledRoundTrips() throws {
        var original = DimensionMapping.defaults(forDimension: 3)
        original.enabled = false
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DimensionMapping.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.enabled)
    }

    // MARK: - Output dedup (RNN output filter)

    func testDedupSuppressesRepeatedNoteWithinWindow() {
        // Same note number re-emitted inside the window: nothing should go
        // out — neither the new note_on nor the paired note_off, so the held
        // note keeps ringing rather than being chopped to silence.
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let first = mapper.encodeOutput(values: [60.0 / 127.0],
                                        now: 100.0,
                                        noteDedupWindow: 0.030)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].statusByte, 0x90)

        let repeat1 = mapper.encodeOutput(values: [60.0 / 127.0],
                                          now: 100.010,
                                          noteDedupWindow: 0.030)
        XCTAssertTrue(repeat1.isEmpty)
    }

    func testDedupAllowsRepeatedNoteOutsideWindow() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0],
                                now: 100.0,
                                noteDedupWindow: 0.030)
        // 50 ms later, outside the 30 ms window — should re-articulate
        // (note_off for previous + note_on for the same note).
        let events = mapper.encodeOutput(values: [60.0 / 127.0],
                                         now: 100.050,
                                         noteDedupWindow: 0.030)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].statusByte, 0x80)
        XCTAssertEqual(events[1].statusByte, 0x90)
    }

    func testDedupWindowZeroDoesNotSuppress() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0],
                                now: 100.0,
                                noteDedupWindow: 0)
        let events = mapper.encodeOutput(values: [60.0 / 127.0],
                                         now: 100.001,
                                         noteDedupWindow: 0)
        XCTAssertEqual(events.count, 2)   // re-articulates: off + on
    }

    func testDedupSuppressesCCWithSameValue() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .controlChange,
                                              channel: 1, number: 74)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [0.5],
                                now: 200.0,
                                ccDedupWindow: 0.030)
        // Same CC value within window — suppressed.
        let same = mapper.encodeOutput(values: [0.5],
                                       now: 200.020,
                                       ccDedupWindow: 0.030)
        XCTAssertTrue(same.isEmpty)
        // Different CC value within window — emitted (only exact MIDI-byte
        // matches dedup with no tolerance).
        let changed = mapper.encodeOutput(values: [0.6],
                                          now: 200.025,
                                          ccDedupWindow: 0.030)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].statusByte, 0xB0)
    }

    func testDedupSuppressesPitchBendWithSameValue() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .pitchBend,
                                              channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [0.5],
                                now: 300.0,
                                ccDedupWindow: 0.030)
        let same = mapper.encodeOutput(values: [0.5],
                                       now: 300.010,
                                       ccDedupWindow: 0.030)
        XCTAssertTrue(same.isEmpty)
    }

    func testDedupIsPerDimension() {
        // Dim 1 reuses its note number; dim 2 is on a different channel/note.
        // Dim 1 gets suppressed; dim 2 fires normally.
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [
                DimensionMapping(id: 1, messageType: .noteOn, channel: 1, number: 0),
                DimensionMapping(id: 2, messageType: .controlChange,
                                 channel: 2, number: 7),
            ]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0, 0.25],
                                now: 400.0,
                                noteDedupWindow: 0.030,
                                ccDedupWindow: 0.030)
        let events = mapper.encodeOutput(values: [60.0 / 127.0, 0.75],
                                         now: 400.010,
                                         noteDedupWindow: 0.030,
                                         ccDedupWindow: 0.030)
        // Note suppressed; CC went through because its value changed.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].statusByte, 0xB1)
    }

    // MARK: - Restricted-dimension encode (inputThru echo)

    func testEncodeRestrictsToProvidedDimensions() {
        // Two output mappings; passing `dimensions: [1]` should emit only
        // dim 2's CC, not dim 1's. Used by the inputThru path so moving one
        // direct-input fader doesn't retrigger every output dimension.
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [
                DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74),
                DimensionMapping(id: 2, messageType: .controlChange, channel: 1, number: 75),
            ]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [0.25, 0.75], dimensions: [1])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data1, 75)
    }

    func testEncodeWithEmptyDimensionsEmitsNothing() {
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [
                DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74),
            ]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [0.5], dimensions: [])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Add / remove / move (decoupled from model dim)

    func testAddInputMappingAppendsAndAssignsId() {
        var mappings = MIDIMappingSet(inputMappings: [], outputMappings: [])
        mappings.addInputMapping()
        mappings.addInputMapping()
        mappings.addInputMapping()
        XCTAssertEqual(mappings.inputMappings.count, 3)
        XCTAssertEqual(mappings.inputMappings.map(\.id), [1, 2, 3])
    }

    func testRemoveInputMappingRenumbersIds() {
        var mappings = MIDIMappingSet.defaults(forModelDimension: 5)
        // Mark each by setting a unique CC number so we can confirm WHICH row
        // remains after deletion of the middle entry.
        for i in mappings.inputMappings.indices {
            mappings.inputMappings[i].number = 50 + i
        }
        mappings.removeInputMapping(at: 1)
        XCTAssertEqual(mappings.inputMappings.count, 3)
        // ids renumbered to match new array positions
        XCTAssertEqual(mappings.inputMappings.map(\.id), [1, 2, 3])
        // The remaining rows are the original 0, 2, 3 (CC 50, 52, 53)
        XCTAssertEqual(mappings.inputMappings.map(\.number), [50, 52, 53])
    }

    func testMoveInputMappingShufflesAndRenumbers() {
        var mappings = MIDIMappingSet.defaults(forModelDimension: 5)
        for i in mappings.inputMappings.indices {
            mappings.inputMappings[i].number = 50 + i
        }
        // Move row at index 3 (CC 53) up to index 0
        mappings.moveInputMapping(from: 3, to: 0)
        XCTAssertEqual(mappings.inputMappings.map(\.number), [53, 50, 51, 52])
        // Ids reflect new positions
        XCTAssertEqual(mappings.inputMappings.map(\.id), [1, 2, 3, 4])
    }

    func testRemoveOutputMappingDoesNotTouchInputs() {
        var mappings = MIDIMappingSet.defaults(forModelDimension: 5)
        let originalInputs = mappings.inputMappings
        mappings.removeOutputMapping(at: 0)
        XCTAssertEqual(mappings.outputMappings.count, 3)
        XCTAssertEqual(mappings.inputMappings, originalInputs)
    }

    func testRemoveAtInvalidIndexIsNoOp() {
        var mappings = MIDIMappingSet.defaults(forModelDimension: 3)
        let snapshot = mappings
        mappings.removeInputMapping(at: 99)
        mappings.removeInputMapping(at: -1)
        XCTAssertEqual(mappings, snapshot)
    }

    // MARK: - Decoupled mapping count semantics

    func testDecodeReflectsArrayPositionAfterReorder() {
        // After reordering, the decoded dim id should reflect the new array
        // position — not the original creation order. Encoding a value through
        // the moved mapping and decoding the bytes back round-trips to the new
        // dim index.
        var mappings = MIDIMappingSet(
            inputMappings: [
                DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 10),
                DimensionMapping(id: 2, messageType: .controlChange, channel: 1, number: 20),
                DimensionMapping(id: 3, messageType: .controlChange, channel: 1, number: 30),
            ],
            outputMappings: []
        )
        // Move CC 30 from dim 3 to dim 1.
        mappings.moveInputMapping(from: 2, to: 0)
        XCTAssertEqual(mappings.inputMappings[0].number, 30)

        let mapper = MIDIMapper(mappings: mappings)
        let bytes: [UInt8] = [0xB0, 30, 64]
        let result = bytes.withUnsafeBufferPointer { buf in
            mapper.decodeInput(bytes: buf.baseAddress!, length: 3)
        }
        // CC 30 now maps to dim 1 (1-based) — id was renumbered after the move.
        XCTAssertEqual(result?.0, 1)
    }

    func testEncodeIgnoresMappingsBeyondValueVector() {
        // Mapping list has 5 rows but the engine only provides 3 values — the
        // extra mappings produce no MIDI (no crash, no stale output).
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [
                DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 10),
                DimensionMapping(id: 2, messageType: .controlChange, channel: 1, number: 20),
                DimensionMapping(id: 3, messageType: .controlChange, channel: 1, number: 30),
                DimensionMapping(id: 4, messageType: .controlChange, channel: 1, number: 40),
                DimensionMapping(id: 5, messageType: .controlChange, channel: 1, number: 50),
            ]
        )
        var mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [0.1, 0.2, 0.3])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.data1), [10, 20, 30])
    }

    func testReleaseAllNotesClearsDedupState() {
        // After releaseAllNotes the dedup clock should reset, so the next
        // emission of the same note re-articulates even within the window.
        let mappings = MIDIMappingSet(
            inputMappings: [],
            outputMappings: [DimensionMapping(id: 1, messageType: .noteOn,
                                              channel: 1, number: 0)]
        )
        var mapper = MIDIMapper(mappings: mappings)
        _ = mapper.encodeOutput(values: [60.0 / 127.0],
                                now: 500.0,
                                noteDedupWindow: 0.030)
        _ = mapper.releaseAllNotes()
        let events = mapper.encodeOutput(values: [60.0 / 127.0],
                                         now: 500.005,
                                         noteDedupWindow: 0.030)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].statusByte, 0x90)
    }
}
