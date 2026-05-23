import Foundation
import TOMLKit

// MARK: - IMPSYConfig
//
// In-memory representation of an IMPSY TOML configuration file
// (see `../impsy/configs/*.toml` for examples). Holds the subset of fields
// the AUv3 plugin understands plus the raw parsed TOMLTable, so any keys
// we don't model (e.g. `[osc]`, `[serial]`, mode != "callresponse") survive
// a round-trip from disk → AU state → disk.
//
// The AUv3-specific deviations from IMPSY's schema (documented in #3):
//   - `in_device` / `out_device` collapse to a single synthetic "AUv3"
//     device on export. On import we read all per-device mapping arrays in
//     the order `in_device` / `out_device` declares, then concatenate.
//   - `[osc]`, `[serial]`, `[websocket]`, `[webui]` etc. are preserved
//     verbatim but otherwise ignored.

struct IMPSYConfig {

    // MARK: - Metadata (preserved on round-trip; not exposed in the UI today)

    var title: String?
    var owner: String?
    var description: String?

    // MARK: - Parameters (the four AU knobs + MIDI thru)

    var threshold: Float = ParameterDefaults.threshold
    var sigmaTemp: Float = ParameterDefaults.sigmaTemp
    var piTemp:    Float = ParameterDefaults.piTemp
    var timescale: Float = ParameterDefaults.timescale
    var inputThru: Bool  = ParameterDefaults.inputThru > 0.5

    // MARK: - Model metadata
    //
    // `modelFile` is stored but never auto-resolved — model loading still
    // goes through the existing security-scoped bookmark workflow. Treat it
    // as a hint to the user, not a path the plugin will open.

    var modelFile:      String?
    var modelDimension: Int?
    var modelSize:      String?

    // MARK: - Mappings (flattened across all input/output devices, in declared order)

    var inputMappings:  [DimensionMapping] = []
    var outputMappings: [DimensionMapping] = []

    // MARK: - Round-trip preservation
    //
    // The raw parsed document. When we serialize we mutate this in place so
    // every section we don't model (`[osc]`, etc.) survives. `nil` when the
    // config was constructed fresh in memory (e.g. from current AU state on
    // export with no prior import).
    private var raw: TOMLTable?

    // MARK: - Synthetic device used on export

    static let synthesizedDeviceName = "AUv3"
}

// MARK: - Parse

extension IMPSYConfig {

    enum ParseError: Error, LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let m): return "Malformed IMPSY config: \(m)"
            }
        }
    }

    static func parse(_ string: String) throws -> IMPSYConfig {
        let table: TOMLTable
        do { table = try TOMLTable(string: string) }
        catch let error as TOMLParseError {
            throw ParseError.malformed(error.localizedDescription)
        }

        var config = IMPSYConfig()
        config.raw = table

        // ── Top-level metadata
        config.title       = table["title"]?.string
        config.owner       = table["owner"]?.string
        config.description = table["description"]?.string

        // ── [interaction]
        if let interaction = table["interaction"]?.table {
            if let t = interaction["threshold"]?.asFloat   { config.threshold = t }
            if let v = interaction["input_thru"]?.bool     { config.inputThru = v }
        }

        // ── [model]
        if let model = table["model"]?.table {
            config.modelFile      = model["file"]?.string
            config.modelDimension = model["dimension"]?.int
            config.modelSize      = model["size"]?.string
            if let v = model["sigmatemp"]?.asFloat { config.sigmaTemp = v }
            if let v = model["pitemp"]?.asFloat    { config.piTemp    = v }
            if let v = model["timescale"]?.asFloat { config.timescale = v }
        }

        // ── [midi]
        if let midi = table["midi"]?.table {
            config.inputMappings  = readMappings(from: midi, deviceKey: "input",  orderKey: "in_device")
            config.outputMappings = readMappings(from: midi, deviceKey: "output", orderKey: "out_device")
        }

        return config
    }

    /// Walk `midi.input` (or `midi.output`) — a table whose entries are
    /// `"DeviceName" = [ <mapping entry>, … ]` — and flatten the per-device
    /// arrays in the order declared by `in_device` / `out_device`. Devices
    /// that exist in the table but aren't listed in the order array are
    /// appended afterwards in encounter order so we never silently drop a
    /// mapping. Each entry's index across the flattened result determines
    /// the dimension it maps to (dim 1 = first entry).
    private static func readMappings(
        from midi: TOMLTable,
        deviceKey: String,
        orderKey: String
    ) -> [DimensionMapping] {
        guard let devices = midi[deviceKey]?.table else { return [] }

        var declaredOrder: [String] = []
        if let arr = midi[orderKey]?.array {
            for entry in arr where entry.string != nil {
                declaredOrder.append(entry.string!)
            }
        }
        var seen = Set(declaredOrder)
        for key in devices.keys where !seen.contains(key) {
            declaredOrder.append(key)
            seen.insert(key)
        }

        var mappings: [DimensionMapping] = []
        for device in declaredOrder {
            guard let array = devices[device]?.array else { continue }
            for entry in array {
                guard let entryArray = entry.array,
                      let mapping = parseMappingEntry(entryArray, dimensionID: mappings.count + 1) else {
                    continue
                }
                mappings.append(mapping)
            }
        }
        return mappings
    }

    /// Convert one IMPSY entry array — e.g. `["control_change", 1, 9, 0, 13]` —
    /// into a `DimensionMapping`. Returns nil for unknown/malformed entries
    /// rather than throwing so a single bad row doesn't kill the whole load.
    private static func parseMappingEntry(_ entry: TOMLArray, dimensionID: Int) -> DimensionMapping? {
        guard entry.count >= 2,
              let typeRaw = entry[0].string,
              let channel = entry[1].int else { return nil }

        switch typeRaw {
        case "note_on":
            // IMPSY's note_on has no fixed note number — the note number IS
            // the dimension's value on input, and the model output drives
            // the emitted note number on output. We keep the existing
            // AUv3 `number` field defaulted to 60 (middle C); see #3 notes
            // about the input-decode semantic gap.
            return DimensionMapping(
                id: dimensionID, messageType: .noteOn,
                channel: channel, number: 60
            )

        case "control_change":
            guard entry.count >= 3, let cc = entry[2].int else { return nil }
            let minV = entry.count >= 5 ? (entry[3].int ?? 0)   : 0
            let maxV = entry.count >= 5 ? (entry[4].int ?? 127) : 127
            return DimensionMapping(
                id: dimensionID, messageType: .controlChange,
                channel: channel, number: cc,
                minValue: minV, maxValue: maxV
            )

        case "pitch_bend":
            return DimensionMapping(
                id: dimensionID, messageType: .pitchBend,
                channel: channel, number: 0
            )

        default:
            return nil
        }
    }
}

// MARK: - Serialize

extension IMPSYConfig {

    enum SerializeError: Error, LocalizedError {
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let m): return "Could not serialize config: \(m)"
            }
        }
    }

    func serialize() throws -> String {
        // Start from the raw doc if we have one (so unknown sections survive)
        // — otherwise build a fresh table from scratch.
        let table: TOMLTable
        if let raw = raw {
            // TOMLTable is a reference type backed by toml++; round-tripping
            // through a TOML string is the cleanest way to clone it without
            // depending on internal copy helpers.
            let cloned = try TOMLTable(string: raw.convert())
            table = cloned
        } else {
            table = TOMLTable()
        }

        // ── Top-level metadata
        if let v = title       { table["title"]       = v.tomlValue }
        if let v = owner       { table["owner"]       = v.tomlValue }
        if let v = description { table["description"] = v.tomlValue }

        // ── [interaction]
        let interaction = (table["interaction"]?.table) ?? TOMLTable()
        interaction["threshold"]  = Double(threshold).tomlValue
        interaction["input_thru"] = inputThru.tomlValue
        // Preserve `mode` if already set; default to "callresponse" otherwise.
        if interaction["mode"] == nil {
            interaction["mode"] = "callresponse".tomlValue
        }
        table["interaction"] = interaction.tomlValue

        // ── [model]
        let model = (table["model"]?.table) ?? TOMLTable()
        if let f = modelFile      { model["file"] = f.tomlValue }
        if let d = modelDimension { model["dimension"] = d.tomlValue }
        if let s = modelSize      { model["size"] = s.tomlValue }
        model["sigmatemp"] = Double(sigmaTemp).tomlValue
        model["pitemp"]    = Double(piTemp).tomlValue
        model["timescale"] = Double(timescale).tomlValue
        table["model"] = model.tomlValue

        // ── [midi] — overwrite all per-device mapping arrays with our single
        // synthesized "AUv3" device. Other keys under [midi] (e.g.
        // `feedback_protection`) survive because we only replace what we own.
        let midi = (table["midi"]?.table) ?? TOMLTable()
        midi["in_device"]  = TOMLArray([Self.synthesizedDeviceName]).tomlValue
        midi["out_device"] = TOMLArray([Self.synthesizedDeviceName]).tomlValue
        midi["input"]  = makeDeviceTable(for: inputMappings).tomlValue
        midi["output"] = makeDeviceTable(for: outputMappings).tomlValue
        table["midi"] = midi.tomlValue

        return table.convert()
    }

    /// Build the `input` / `output` per-device sub-table — a single entry
    /// keyed by `"AUv3"` whose value is an array of mapping arrays.
    private func makeDeviceTable(for mappings: [DimensionMapping]) -> TOMLTable {
        let entries = TOMLArray()
        for m in mappings {
            entries.append(makeMappingEntry(m))
        }
        let device = TOMLTable()
        device[Self.synthesizedDeviceName] = entries.tomlValue
        return device
    }

    /// IMPSY's positional entry format:
    ///   noteOn          → ["note_on", channel]
    ///   controlChange   → ["control_change", channel, cc]    (or 5-tuple if range)
    ///   pitchBend       → ["pitch_bend", channel]
    private func makeMappingEntry(_ m: DimensionMapping) -> TOMLArray {
        let arr = TOMLArray()
        switch m.messageType {
        case .noteOn:
            arr.append("note_on")
            arr.append(m.channel)
        case .controlChange:
            arr.append("control_change")
            arr.append(m.channel)
            arr.append(m.number)
            if m.minValue != 0 || m.maxValue != 127 {
                arr.append(m.minValue)
                arr.append(m.maxValue)
            }
        case .pitchBend:
            arr.append("pitch_bend")
            arr.append(m.channel)
        }
        return arr
    }
}

// MARK: - Helpers

private extension TOMLValueConvertible {
    /// TOML treats `1` and `1.0` as different types. Most numeric IMPSY
    /// fields (threshold, sigmatemp, …) are floats in spirit but configs in
    /// the wild mix integer and float literals, so we accept both.
    var asFloat: Float? {
        if let d = self.double { return Float(d) }
        if let i = self.int    { return Float(i) }
        return nil
    }
}
