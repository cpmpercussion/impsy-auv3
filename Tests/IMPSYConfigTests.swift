import XCTest
// Common sources are compiled directly into this test target (see project.yml)

final class IMPSYConfigTests: XCTestCase {

    // MARK: - Fixture helpers

    private func readFixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: name, withExtension: "toml"),
            "Fixture \(name).toml must be bundled with the test target"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - AiC u6midipro config (matches our hardcoded AiC default)

    func testParseAiCU6MIDIProConfig() throws {
        let toml = try readFixture("AiC-charles-u6midipro")
        let config = try IMPSYConfig.parse(toml)

        XCTAssertEqual(config.title, "RPi U6MIDI Pro: nanoKontrol Studio to notes and CCs")
        XCTAssertEqual(config.owner, "Charles Martin")

        XCTAssertEqual(config.threshold, 0.1, accuracy: 1e-6)
        XCTAssertEqual(config.sigmaTemp, 0.01, accuracy: 1e-6)
        XCTAssertEqual(config.piTemp,    1.0,  accuracy: 1e-6)
        XCTAssertEqual(config.timescale, 1.0,  accuracy: 1e-6)
        XCTAssertEqual(config.inputThru, true)

        XCTAssertEqual(config.modelDimension, 9)

        // 8 input CCs (nanoKONTROL Studio knobs)
        XCTAssertEqual(config.inputMappings.count, 8)
        for (i, m) in config.inputMappings.enumerated() {
            XCTAssertEqual(m.messageType, .controlChange)
            XCTAssertEqual(m.channel, 1)
            XCTAssertEqual(m.number, 13 + i)
            XCTAssertEqual(m.minValue, 0)
            XCTAssertEqual(m.maxValue, 127)
        }

        // 8 outputs interleaving note_on (no number — sentinel 60 in our model)
        // and CC on channel 11.
        XCTAssertEqual(config.outputMappings.count, 8)
        for (i, m) in config.outputMappings.enumerated() {
            if i.isMultiple(of: 2) {
                XCTAssertEqual(m.messageType, .noteOn)
                XCTAssertEqual(m.channel, i / 2 + 1)
            } else {
                XCTAssertEqual(m.messageType, .controlChange)
                XCTAssertEqual(m.channel, 11)
                XCTAssertEqual(m.number, i / 2 + 1)
            }
        }
    }

    // MARK: - Roland S-1 + X-TOUCH (multi-device + 5-tuple ranges)

    func testParseXTouchConfigDecodesRangeTuples() throws {
        let toml = try readFixture("roland-s-1-xtouch")
        let config = try IMPSYConfig.parse(toml)

        // `in_device = ["S-1", "X-TOUCH"]` — S-1 entries come first, X-TOUCH second.
        // S-1 input is 8 entries (one note_on + seven control_change).
        XCTAssertGreaterThanOrEqual(config.inputMappings.count, 8 + 8)
        XCTAssertEqual(config.inputMappings.first?.messageType, .noteOn)
        XCTAssertEqual(config.inputMappings.first?.channel, 3)

        // X-TOUCH output is 8 control_change entries WITH min/max = 0,13.
        // They come after the S-1 outputs (which is 8 entries). So indices 8…15.
        let xtouchOutputs = Array(config.outputMappings[8..<16])
        XCTAssertEqual(xtouchOutputs.count, 8)
        for (i, m) in xtouchOutputs.enumerated() {
            XCTAssertEqual(m.messageType, .controlChange)
            XCTAssertEqual(m.channel, 1)
            XCTAssertEqual(m.number, 9 + i)
            XCTAssertEqual(m.minValue, 0)
            XCTAssertEqual(m.maxValue, 13)
        }
    }

    // MARK: - Round-trip: parse → serialize → parse equals first parse

    func testRoundTripPreservesKnownFields() throws {
        let toml = try readFixture("AiC-charles-u6midipro")
        let first = try IMPSYConfig.parse(toml)
        let serialized = try first.serialize()
        let second = try IMPSYConfig.parse(serialized)

        XCTAssertEqual(second.title,     first.title)
        XCTAssertEqual(second.owner,     first.owner)
        XCTAssertEqual(second.threshold, first.threshold)
        XCTAssertEqual(second.sigmaTemp, first.sigmaTemp)
        XCTAssertEqual(second.piTemp,    first.piTemp)
        XCTAssertEqual(second.timescale, first.timescale)
        XCTAssertEqual(second.inputThru, first.inputThru)
        XCTAssertEqual(second.modelDimension, first.modelDimension)

        // Mappings round-trip — note that exporting collapses everything under
        // the synthetic "AUv3" device, so on re-parse all entries come back
        // through one device list. Comparing IDs would mis-match, so we
        // compare the substantive fields only.
        XCTAssertEqual(second.inputMappings.map(\.messageType),
                       first.inputMappings.map(\.messageType))
        XCTAssertEqual(second.outputMappings.map(\.messageType),
                       first.outputMappings.map(\.messageType))
        XCTAssertEqual(second.outputMappings.map(\.channel),
                       first.outputMappings.map(\.channel))
    }

    func testRoundTripPreservesRangeTuples() throws {
        let toml = try readFixture("roland-s-1-xtouch")
        let first = try IMPSYConfig.parse(toml)
        let serialized = try first.serialize()
        let second = try IMPSYConfig.parse(serialized)

        XCTAssertEqual(second.outputMappings.map(\.minValue),
                       first.outputMappings.map(\.minValue))
        XCTAssertEqual(second.outputMappings.map(\.maxValue),
                       first.outputMappings.map(\.maxValue))
    }

    // MARK: - Unknown keys survive round-trip

    func testRoundTripPreservesUnknownSections() throws {
        // microfreak.toml has no unknown sections we care about, but adding a
        // synthetic [osc] table to a config and round-tripping must keep it.
        let toml = """
        title = "test"

        [interaction]
        threshold = 0.2

        [midi]
        in_device = ["AUv3"]
        out_device = ["AUv3"]
        input."AUv3" = []
        output."AUv3" = []

        [osc]
        server_ip = "0.0.0.0"
        server_port = 6000
        """
        let parsed = try IMPSYConfig.parse(toml)
        let serialized = try parsed.serialize()

        XCTAssertTrue(serialized.contains("[osc]"),
                      "Expected the [osc] section to survive the round-trip:\n\(serialized)")
        XCTAssertTrue(serialized.contains("server_port"),
                      "Expected [osc].server_port to survive:\n\(serialized)")
    }

    // MARK: - Export from default-constructed config

    func testSerializeFreshConfigProducesValidTOML() throws {
        var config = IMPSYConfig()
        config.title = "exported"
        config.threshold = 0.25
        config.inputMappings = [
            DimensionMapping(id: 1, messageType: .controlChange, channel: 1, number: 74,
                             minValue: 0, maxValue: 127),
            DimensionMapping(id: 2, messageType: .noteOn, channel: 2, number: 60),
        ]
        config.outputMappings = config.inputMappings
        let serialized = try config.serialize()

        // Re-parse to confirm the output is valid TOML and round-trips.
        let reparsed = try IMPSYConfig.parse(serialized)
        XCTAssertEqual(reparsed.title, "exported")
        XCTAssertEqual(reparsed.threshold, 0.25, accuracy: 1e-6)
        XCTAssertEqual(reparsed.inputMappings.count, 2)
        XCTAssertEqual(reparsed.inputMappings[0].messageType, .controlChange)
        XCTAssertEqual(reparsed.inputMappings[1].messageType, .noteOn)
    }
}
