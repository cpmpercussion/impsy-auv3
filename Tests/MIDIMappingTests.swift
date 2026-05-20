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
        let mapper = MIDIMapper(mappings: mappings)
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
        let mapper = MIDIMapper(mappings: mappings)
        let events = mapper.encodeOutput(values: [1.5])   // out of range
        XCTAssertEqual(events[0].data2, 127)
    }

    // MARK: - Codable round-trip

    func testMappingSetRoundTrips() throws {
        let original = MIDIMappingSet.defaults(forModelDimension: 5)
        let data      = try JSONEncoder().encode(original.inputMappings)
        let decoded   = try JSONDecoder().decode([DimensionMapping].self, from: data)
        XCTAssertEqual(decoded, original.inputMappings)
    }
}
