import XCTest
// Common sources are compiled directly into this test target (see project.yml)

// MARK: - IMPSY conformance vectors
//
// Runs IMPSY's conformance vectors (../impsy/spec/, copied into
// Tests/Conformance/ by scripts/update_conformance_vectors.sh) against the
// AUv3's own mapping, engine and model code. Each vector file records what
// IMPSY Python does for a list of cases; every case here feeds the same
// inputs through the Swift code and compares with `expected`.
//
// Following ../impsy/spec/README.md:
//   - floats are compared within the file's tolerance, raised to 1e-6
//     because the AUv3 works in Float32;
//   - a case the AUv3 knowingly differs on is listed in `knownDivergences`
//     with the reason. It still runs, inside XCTExpectFailure(strict:), so
//     fixing the divergence makes the test fail until the entry is removed;
//   - vector files that don't apply to the AUv3 are skipped with a reason.

final class ConformanceTests: XCTestCase {

    /// The spec version these tests were written against. A new major version
    /// means expected behaviour changed, so updating is a deliberate step.
    static let supportedSpecMajor = 1

    /// Float32 can't hold the vectors' float64 values to 1e-9.
    static let float32Tolerance = 1e-6

    /// Cases where the AUv3 knowingly differs from IMPSY, keyed by
    /// "file::case". Remove an entry once the AUv3 matches.
    static let knownDivergences: [String: String] = [
        // ── MIDI input ────────────────────────────────────────────────────
        // AUv3 note_on input matches one fixed note number (default 60 on
        // TOML import) and uses velocity as the value; IMPSY matches any
        // note on the channel and uses note / 127.
        "midi_input::note_on_value_is_pitch": "note_on input decodes velocity, not pitch",
        "midi_input::channels_are_one_based_in_config": "note_on input decodes velocity, not pitch",
        "midi_input::fixed_velocity_note_input": "note_on input decodes velocity, not pitch; 3-element note_on not parsed",
        // AUv3 treats velocity-0 note-on as a value of 0, not a note-off.
        "midi_input::note_on_velocity_zero": "velocity-0 note-on is not ignored",
        // AUv3 decode stops at the first matching mapping.
        "midi_input::same_cc_with_different_ranges": "a message only updates the first matching dimension",
        "midi_input::duplicate_mapping_sets_every_dimension": "a message only updates the first matching dimension",
        "midi_input::note_velocity_pairs_with_notes": "note_velocity mapping type not supported",
        // ── MIDI output ───────────────────────────────────────────────────
        // AUv3 sends note-ons at velocity 64; IMPSY uses 127.
        "midi_output::note_and_cc_encoding": "note-on velocity 64, not 127",
        "midi_output::monophonic_note_offs": "note-on velocity 64, not 127",
        "midi_output::all_notes_off": "note-on velocity 64, not 127",
        "midi_output::values_clipped_to_unit_range": "note-on velocity 64, not 127",
        "midi_output::output_boundary_values": "note-on velocity 64, not 127",
        // AUv3 tracks the last note per channel, not per dimension.
        "midi_output::polyphonic_notes_on_one_channel": "note-offs are tracked per channel, not per dimension",
        "midi_output::note_velocity_output": "note_velocity mapping type not supported",
        "midi_output::fixed_velocity_output": "3-element note_on (fixed velocity) not parsed",
        // AUv3 suppresses repeats within a time window (response output
        // only); IMPSY suppresses any CC/pitch bend equal to the last sent.
        "midi_output::unchanged_cc_and_pitch_bend_not_resent": "unchanged CC / pitch bend values are resent",
        // ── Pipeline ──────────────────────────────────────────────────────
        "pipeline::sparse_midi_to_dense_model_input": "note_on input decodes velocity, not pitch",
        "pipeline::one_message_is_one_interaction": "note_on input decodes velocity, not pitch; first-match decode",
        "pipeline::ignored_messages_do_not_reset_dt": "note_on input decodes velocity, not pitch",
        "pipeline::note_and_velocity_are_one_interaction": "note_velocity mapping type not supported",
        // ── Playback ──────────────────────────────────────────────────────
        // AUv3 feeds the timescaled dt back to the RNN; IMPSY feeds the
        // unscaled dt (impsy#103).
        "playback::timescale_and_clamping": "timescaled dt fed back to the model",
        "playback::slower_timescale": "timescaled dt fed back to the model",
    ]

    /// Vector files that describe IMPSY features the AUv3 doesn't have.
    static let notApplicable: [String: String] = [
        "websocket_input.json": "the AUv3 has no WebSocket IO",
        "websocket_output.json": "the AUv3 has no WebSocket IO",
        "dataset.json": "datasets are built from logs by IMPSY Python, not the AUv3",
    ]

    // MARK: - Tests

    func testSpecVersionIsSupported() throws {
        for (name, document) in try Self.loadDocuments() {
            let version = try XCTUnwrap(document["spec_version"]?.string, name)
            let major = Int(version.split(separator: ".").first ?? "")
            XCTAssertEqual(major, Self.supportedSpecMajor,
                           "\(name) is spec \(version); check what changed before updating")
        }
    }

    func testEveryVectorFileIsHandled() throws {
        let handled = Set(Self.runners.keys).union(Self.notApplicable.keys)
        XCTAssertEqual(Set(try Self.loadDocuments().keys), handled,
                       "Add a runner or a notApplicable entry for new vector files")
    }

    func testKnownDivergencesNameRealCases() throws {
        let documents = try Self.loadDocuments()
        let caseIDs = Set(documents.flatMap { name, document in
            (document["cases"]?.array ?? []).map { Self.caseID(name, $0) }
        })
        for id in Self.knownDivergences.keys {
            XCTAssertTrue(caseIDs.contains(id), "knownDivergences lists unknown case \(id)")
        }
    }

    func testMIDIInput() throws  { try run("midi_input.json") }
    func testMIDIOutput() throws { try run("midi_output.json") }
    func testPipeline() throws   { try run("pipeline.json") }
    func testPlayback() throws   { try run("playback.json") }
    func testModel() throws      { try run("model.json") }

    func testWebSocketInput() throws  { try run("websocket_input.json") }
    func testWebSocketOutput() throws { try run("websocket_output.json") }
    func testDataset() throws         { try run("dataset.json") }

    // MARK: - Case runner

    private func run(_ filename: String) throws {
        if let reason = Self.notApplicable[filename] {
            throw XCTSkip("\(filename): \(reason)")
        }
        let document = try XCTUnwrap(try Self.loadDocuments()[filename], "missing \(filename)")
        let runner = try XCTUnwrap(Self.runners[filename])
        let tolerance = max(document["tolerance"]?.number ?? 0, Self.float32Tolerance)
        let cases = try XCTUnwrap(document["cases"]?.array)
        XCTAssertFalse(cases.isEmpty)

        for testCase in cases {
            let id = Self.caseID(filename, testCase)
            XCTContext.runActivity(named: id) { _ in
                let check = {
                    do {
                        let actual = try runner(testCase)
                        let expected = testCase["expected"] ?? .null
                        if let diff = JSON.mismatch(actual, expected, tolerance: tolerance) {
                            XCTFail("\(id): \(diff)")
                        }
                    } catch {
                        XCTFail("\(id): \(error)")
                    }
                }
                if let reason = Self.knownDivergences[id] {
                    let options = XCTExpectedFailure.Options()
                    options.isStrict = true
                    XCTExpectFailure("\(id): \(reason)", options: options, failingBlock: check)
                } else {
                    check()
                }
            }
        }
    }

    private static func caseID(_ filename: String, _ testCase: JSON) -> String {
        let stem = filename.hasSuffix(".json") ? String(filename.dropLast(5)) : filename
        return "\(stem)::\(testCase["name"]?.string ?? "?")"
    }

    // MARK: - Runners: one per vector file, returning that case's "expected"

    private static let runners: [String: (JSON) throws -> JSON] = [
        "midi_input.json": runMIDIInput,
        "midi_output.json": runMIDIOutput,
        "pipeline.json": runPipeline,
        "playback.json": runPlayback,
        "model.json": runModel,
    ]

    /// Each MIDI message → the [index, value] updates it makes, or null.
    /// A fresh mapper per message, as IMPSY uses a fresh server per message.
    private static func runMIDIInput(_ c: JSON) throws -> JSON {
        let mappings = try mappingSet(input: c["input_mapping"])
        return .array(try c.req("messages").req().map { message in
            let bytes = try midiBytes(message)
            let mapper = MIDIMapper(mappings: mappings)
            let update = bytes.withUnsafeBufferPointer {
                mapper.denseUpdate(fromBytes: $0.baseAddress!, length: $0.count)
            }
            guard let (index, value) = update else { return .null }
            return .array([.array([.number(Double(index)), .number(Double(value))])])
        })
    }

    /// Output steps → MIDI bytes sent at each step. One mapper per case so
    /// note state carries across steps. `all_notes_off` is what the engine
    /// does on mode, model and mapping changes.
    private static func runMIDIOutput(_ c: JSON) throws -> JSON {
        var mapper = MIDIMapper(mappings: try mappingSet(output: c["output_mapping"]))
        return .array(try c.req("steps").req().map { step in
            let events: [MIDIEvent]
            if step["all_notes_off"]?.bool == true {
                events = mapper.releaseAllNotes()
            } else {
                events = mapper.encodeOutput(values: try floats(step.req("values")))
            }
            return .array(events.map { event in
                .array([event.statusByte, event.data1, event.data2]
                        .prefix(event.byteCount).map { .number(Double($0)) })
            })
        })
    }

    /// Timed MIDI events → model inputs and 'interface' log rows, through
    /// the same ingest step the engine's 10 ms tick runs, one event per tick.
    private static func runPipeline(_ c: JSON) throws -> JSON {
        let mapper = MIDIMapper(mappings: try mappingSet(input: c["input_mapping"]))
        var inputVector = try floats(c.req("initial_values"))
        var lastTime = try c.req("start_time").req() as Double
        var modelInputs: [JSON] = []
        var log: [JSON] = []
        for event in try c.req("events").req() as [JSON] {
            let b = try midiBytes(event.req("bytes"))
            let packet = RawMIDIPacket(b[0], b.count > 1 ? b[1] : 0, b.count > 2 ? b[2] : 0,
                                       length: b.count)
            guard let result = InteractionEngine.ingest(
                [packet], at: try event.req("time").req(), mapper: mapper,
                inputVector: &inputVector, lastUserInputTime: &lastTime) else { continue }
            modelInputs.append(.floats(result.interaction))
            log += result.logRows.map { .object(["source": .string("interface"), "values": .floats($0)]) }
        }
        return .object(["model_inputs": .array(modelInputs), "log": .array(log)])
    }

    /// Model outputs [dt, x…] (after ÷10) → wait, values played, next input.
    /// The AUv3 clamps dt and clips values in MDNSampler.postProcess, then
    /// applies timescale in prepareResponsePlayback; this runs both.
    private static func runPlayback(_ c: JSON) throws -> JSON {
        let timescale = Float(try c.req("timescale").req() as Double)
        return .array(try c.req("model_outputs").req().map { item in
            let raw = try floats(item).map { $0 * IMPSYConstants.scaleFactor }
            let output = MDNSampler.postProcess(raw)
            let (wait, values, next) = InteractionEngine.prepareResponsePlayback(
                output: output, timescale: timescale)
            return .object(["wait": .number(wait), "output": .floats(values),
                            "next_model_input": .floats(next)])
        })
    }

    /// Input vectors → scaled input, raw MDN output and mixture parameters,
    /// through ModelInspector and TFLiteRNN on the committed fixed-weight model.
    private static func runModel(_ c: JSON) throws -> JSON {
        let url = try resourceURL(c.req("model_file").req())
        let config = try ModelInspector.inspect(modelURL: url)
        let rnn = try TFLiteRNN(modelData: try Data(contentsOf: url), config: config)
        let piTemp = Float(try c.req("pi_temp").req() as Double)
        let sigmaTemp = Float(try c.req("sigma_temp").req() as Double)
        let draws = try floats(c.req("uniform_draws"))
        let (d, m) = (config.dimension, config.numMixtures)
        let scale = IMPSYConstants.scaleFactor

        let steps: [JSON] = try c.req("steps").req().map { step in
            if step["reset"]?.bool == true {
                rnn.resetStates()
                return .null
            }
            let input = try floats(step.req("input"))
            let params = try rnn.mdnOutput(input: input)
            let (mus, sigmas, piLogits) = try XCTUnwrap(
                MDNSampler.split(params: params, dimension: d, numMixtures: m))
            let pis = MDNSampler.softmaxWithTemperature(piLogits, temperature: piTemp)
            let rows = { (flat: [Float], f: (Float) -> Float) -> JSON in
                .array((0..<m).map { k in .floats(flat[k * d ..< (k + 1) * d].map(f)) })
            }
            return .object([
                "model_input": .floats(TFLiteRNN.scaledInput(input)),
                "mdn_output": .floats(params),
                "pi": .floats(pis),
                "mu": rows(mus) { $0 / scale },
                "std": rows(sigmas) { $0 * sqrtf(sigmaTemp) / scale },
                "mixture_for_draw": .array(draws.map {
                    .number(Double(MDNSampler.sampleCategorical(pis, draw: $0)))
                }),
            ])
        }

        let names = try rnn.resolvedTensorNames()
        return .object([
            "introspected": .object([
                "dimension": .number(Double(config.dimension)),
                "units": .number(Double(config.hiddenUnits)),
                "mixtures": .number(Double(config.numMixtures)),
                "layers": .number(Double(config.numLayers)),
            ]),
            "tensors": .object([
                "inputs": .array(names.inputs.map { .string($0) }),
                "mdn_output": .string(names.mdnOutput),
                "state_outputs": .object(names.stateOutputs.mapValues { .string($0) }),
            ]),
            "steps": .array(steps),
        ])
    }

    // MARK: - Helpers

    /// Build mappings from IMPSY config arrays by going through the AUv3's own
    /// TOML import, so the tests cover how a config.toml would load.
    private static func mappingSet(input: JSON? = nil, output: JSON? = nil) throws -> MIDIMappingSet {
        let toml = """
            [midi]
            in_device = ["in"]
            out_device = ["out"]
            [midi.input]
            in = \(try (input ?? .array([])).tomlLiteral())
            [midi.output]
            out = \(try (output ?? .array([])).tomlLiteral())
            """
        let config = try IMPSYConfig.parse(toml)
        // IMPSYConfig drops entries it can't parse, which would shift every
        // later dimension. Report that rather than compare misaligned values.
        let (inCount, outCount) = (input?.array?.count ?? 0, output?.array?.count ?? 0)
        guard config.inputMappings.count == inCount, config.outputMappings.count == outCount else {
            throw ConformanceError("mapping not supported by IMPSYConfig: \(input ?? .null) / \(output ?? .null)")
        }
        return MIDIMappingSet(inputMappings: config.inputMappings,
                              outputMappings: config.outputMappings)
    }

    private static func midiBytes(_ json: JSON) throws -> [UInt8] {
        try (json.req() as [JSON]).map { UInt8(try $0.req() as Double) }
    }

    private static func floats(_ json: JSON) throws -> [Float] {
        try (json.req() as [JSON]).map { Float(try $0.req() as Double) }
    }

    private static func resourceURL(_ relativePath: String) throws -> URL {
        let root = try XCTUnwrap(Bundle(for: ConformanceTests.self)
            .url(forResource: "Conformance", withExtension: nil),
            "Conformance folder missing from test bundle; run xcodegen generate")
        return root.appendingPathComponent(relativePath)
    }

    private static func loadDocuments() throws -> [String: JSON] {
        let dir = try resourceURL("vectors")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var documents: [String: JSON] = [:]
        for file in files where file.pathExtension == "json" {
            documents[file.lastPathComponent] = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: file))
        }
        return documents
    }
}

// MARK: - JSON

struct ConformanceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal JSON value for reading vectors and building actual results.
enum JSON: Decodable, CustomStringConvertible {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    static func floats(_ values: [Float]) -> JSON { .array(values.map { .number(Double($0)) }) }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool?     { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON]?  { if case .array(let a) = self { return a }; return nil }

    func req(_ key: String) throws -> JSON {
        guard let value = self[key] else { throw ConformanceError("missing key \(key)") }
        return value
    }
    func req() throws -> [JSON] {
        guard let a = array else { throw ConformanceError("expected array, got \(self)") }
        return a
    }
    func req() throws -> Double {
        guard let n = number else { throw ConformanceError("expected number, got \(self)") }
        return n
    }
    func req() throws -> String {
        guard let s = string else { throw ConformanceError("expected string, got \(self)") }
        return s
    }

    /// An inline TOML literal for a mapping entry: arrays of strings and integers.
    func tomlLiteral() throws -> String {
        switch self {
        case .array(let a): return "[" + (try a.map { try $0.tomlLiteral() }).joined(separator: ", ") + "]"
        case .string(let s): return "\"\(s)\""
        case .number(let n) where n == n.rounded(): return String(Int(n))
        default: throw ConformanceError("can't write \(self) as a mapping entry")
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n): return String(n)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\"\($0)\": \(o[$0]!)" }.joined(separator: ", ") + "}"
        }
    }

    /// The first difference between `actual` and `expected`, or nil. Numbers
    /// match within `tolerance`, everything else exactly — like `mismatch`
    /// in ../impsy/impsy/conformance.py.
    static func mismatch(_ actual: JSON, _ expected: JSON, tolerance: Double, path: String = "$") -> String? {
        switch (actual, expected) {
        case (.null, .null): return nil
        case let (.bool(a), .bool(e)) where a == e: return nil
        case let (.string(a), .string(e)) where a == e: return nil
        case let (.number(a), .number(e)):
            return abs(a - e) <= tolerance ? nil : "\(path): \(a) != \(e) (tolerance \(tolerance))"
        case let (.array(a), .array(e)) where a.count == e.count:
            for (i, (x, y)) in zip(a, e).enumerated() {
                if let found = mismatch(x, y, tolerance: tolerance, path: "\(path)[\(i)]") { return found }
            }
            return nil
        case let (.object(a), .object(e)) where Set(a.keys) == Set(e.keys):
            for key in e.keys.sorted() {
                if let found = mismatch(a[key]!, e[key]!, tolerance: tolerance, path: "\(path).\(key)") { return found }
            }
            return nil
        default:
            return "\(path): \(actual) != \(expected)"
        }
    }
}
