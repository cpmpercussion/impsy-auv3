import Foundation

// MARK: - Parsed MIDI Event

struct MIDIEvent {
    let statusByte: UInt8   // e.g. 0x90 for note-on ch1
    let data1: UInt8        // note or CC number
    let data2: UInt8        // velocity or value
    let byteCount: Int      // 1, 2, or 3

    /// Convenience for 3-byte messages
    init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) {
        statusByte = b0; data1 = b1; data2 = b2; byteCount = 3
    }

    /// MIDI channel 1–16 extracted from status byte
    var channel: Int { Int(statusByte & 0x0F) + 1 }

    /// Returns raw bytes for use with midiOutputEventBlock
    func withBytes<T>(_ body: (UnsafePointer<UInt8>, Int) -> T) -> T {
        let bytes: [UInt8] = [statusByte, data1, data2]
        return bytes.withUnsafeBufferPointer { buf in
            body(buf.baseAddress!, byteCount)
        }
    }

    /// Short human-readable description, e.g. "Note 67 ch1" or "CC11=80 ch11".
    var summary: String {
        switch statusByte & 0xF0 {
        case 0x90: return "Note \(data1) ch\(channel)"
        case 0xB0: return "CC\(data1)=\(data2) ch\(channel)"
        case 0xE0: return "Bend ch\(channel)"
        default:   return String(format: "0x%02X ch%d", statusByte, channel)
        }
    }
}

// MARK: - MIDIMapper

/// Translates between raw MIDI bytes and normalised [0,1] dimension values.
///
/// Follows IMPSY Python (../impsy/impsy/utils.py): decode is
/// `midi_message_to_updates`, encode is `MidiOutputState`.
struct MIDIMapper {

    var mappings: MIDIMappingSet {
        didSet { if mappings.outputMappings != oldValue.outputMappings { resetOutputState() } }
    }

    // Output note state, per output dimension (0-based index) in the order
    // the notes started, so all-notes-off matches IMPSY's order. Each entry
    // is (dimension, 0-based channel, note).
    private var sounding: [(dim: Int, channel: UInt8, note: UInt8)] = []

    // Last CC / pitch-bend value sent, so unchanged values aren't resent
    // (impsy#110). Keyed per channel+controller (CC) or per channel (bend).
    private enum SentKey: Hashable {
        case cc(channel: UInt8, control: UInt8)
        case pitchBend(channel: UInt8)
    }
    private var lastSent: [SentKey: Int] = [:]

    // Per-output-dimension last note emission (note + time), for the note
    // dedup window on encodeOutput(values:now:noteDedupWindow:). AUv3-only;
    // IMPSY always sends notes (proposed upstream in cpmpercussion/impsy#123).
    private var lastNoteEmissions: [Int: (note: UInt8, time: TimeInterval)] = [:]

    init(mappings: MIDIMappingSet) {
        self.mappings = mappings
    }

    // MARK: Decode (MIDI → normalised value)

    /// Given raw MIDI bytes, returns every `(dimensionIndex, normalizedValue)`
    /// update the message makes, in mapping order — empty if it matches no
    /// input mapping. `dimensionIndex` is 1-based (matches model dims 1…N).
    ///
    /// A message sets every dimension it's mapped to (impsy#102), each CC
    /// scaled by its own range (impsy#105). A note-on sets `noteOn` dims on
    /// its channel to `note / 127` and `noteVelocity` dims to
    /// `velocity / 127` (impsy#98); velocity-0 note-ons are note-offs and
    /// set nothing (impsy#99).
    func decodeInput(bytes: UnsafePointer<UInt8>, length: Int) -> [(Int, Float)] {
        guard length >= 2 else { return [] }
        let status = bytes[0]
        let messageType = status & 0xF0
        let channel = Int(status & 0x0F) + 1
        let data2 = length >= 3 ? bytes[2] : 0

        var updates: [(Int, Float)] = []
        for mapping in mappings.inputMappings {
            guard mapping.enabled, mapping.channel == channel else { continue }
            switch (mapping.messageType, messageType) {
            case (.noteOn, 0x90) where length >= 3 && data2 > 0:
                updates.append((mapping.id, Float(bytes[1]) / 127.0))
            case (.noteVelocity, 0x90) where length >= 3 && data2 > 0:
                updates.append((mapping.id, Float(data2) / 127.0))
            case (.controlChange, 0xB0) where bytes[1] == UInt8(mapping.number & 0x7F):
                updates.append((mapping.id, mapping.normalize(ccValue: Int(data2))))
            case (.pitchBend, 0xE0):
                let raw = (Int(data2) << 7) | Int(bytes[1])   // 0–16383
                updates.append((mapping.id, Float(raw) / 16383.0))
            default:
                continue
            }
        }
        return updates
    }

    // MARK: Encode (normalised value → MIDI)

    /// Given a model output vector (index 0 = dim 1), produce MIDI events for each dimension.
    /// `values` is 0-based: values[0] → dimension 1, values[1] → dimension 2, etc.
    ///
    /// Matches IMPSY's `MidiOutputState.messages`:
    ///   - Notes are tracked per dimension, so note dims sharing a channel
    ///     play together. Before a dim plays a new note its previous note is
    ///     turned off, unless another dim on that channel still holds it.
    ///   - A note's velocity comes from the first `noteVelocity` dim on its
    ///     channel (`max(1, round(v * 127))`), else the mapping's fixed
    ///     velocity, else 127. `noteVelocity` dims send nothing themselves.
    ///   - CC and pitch bend are only sent when their MIDI value differs from
    ///     the last one sent to that channel (and controller). Notes are
    ///     always sent.
    ///
    /// When `dimensions` is non-nil, only output mappings at those indices are
    /// emitted — used by the inputThru path so moving one input echoes through
    /// only its own output mapping, not every dimension's.
    ///
    /// When `now` is non-nil and `noteDedupWindow` > 0, a note dimension is
    /// suppressed if it would replay the same note within that window
    /// (AUv3-only, response output only). A suppressed note also omits its
    /// note-off so the held note keeps ringing rather than being chopped.
    mutating func encodeOutput(values: [Float],
                                dimensions: Set<Int>? = nil,
                                now: TimeInterval? = nil,
                                noteDedupWindow: TimeInterval = 0) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        let outputs = mappings.outputMappings
        for (i, mapping) in outputs.enumerated() {
            guard i < values.count else { break }
            guard mapping.enabled else { continue }
            if let dimensions, !dimensions.contains(i) { continue }
            let v = values[i].clamped(to: 0...1)
            let ch = UInt8(mapping.channel - 1) & 0x0F

            switch mapping.messageType {
            case .noteOn:
                let note = UInt8(clamping: Self.midiValue(v))
                if let now, noteDedupWindow > 0,
                   let last = lastNoteEmissions[i],
                   last.note == note,
                   (now - last.time) < noteDedupWindow {
                    continue
                }
                if let p = sounding.firstIndex(where: { $0.dim == i }) {
                    let previous = sounding.remove(at: p)
                    let heldElsewhere = sounding.contains {
                        $0.channel == previous.channel && $0.note == previous.note
                    }
                    if !heldElsewhere {
                        events.append(MIDIEvent(0x80 | previous.channel, previous.note, 0))
                    }
                }
                let velocity = Self.velocity(for: mapping, outputs: outputs, values: values)
                events.append(MIDIEvent(0x90 | ch, note, velocity))
                sounding.append((i, ch, note))
                if let now { lastNoteEmissions[i] = (note, now) }
            case .noteVelocity:
                continue
            case .controlChange:
                let ccVal = mapping.denormalize(toCCValue: v)
                let control = UInt8(mapping.number & 0x7F)
                guard changed(.cc(channel: ch, control: control), to: ccVal) else { continue }
                events.append(MIDIEvent(0xB0 | ch, control, UInt8(clamping: ccVal)))
            case .pitchBend:
                let raw = Int(v * 16383.0 + 0.5)
                guard changed(.pitchBend(channel: ch), to: raw) else { continue }
                events.append(MIDIEvent(0xE0 | ch, UInt8(raw & 0x7F), UInt8((raw >> 7) & 0x7F)))
            }
        }
        return events
    }

    /// Emit a note_off for every sounding (channel, note), in the order the
    /// notes started, then forget them. Also forgets the last CC and pitch
    /// bend values, so the next step sends them all. Call at mode/model
    /// transitions so the last RNN-emitted note does not hang on the
    /// receiving synth. Matches IMPSY's `MidiOutputState.all_notes_off`.
    mutating func releaseAllNotes() -> [MIDIEvent] {
        var offs: [MIDIEvent] = []
        var seen = Set<UInt16>()
        for s in sounding where seen.insert(UInt16(s.channel) << 8 | UInt16(s.note)).inserted {
            offs.append(MIDIEvent(0x80 | s.channel, s.note, 0))
        }
        resetOutputState()
        return offs
    }

    private mutating func resetOutputState() {
        sounding.removeAll()
        lastSent.removeAll()
        lastNoteEmissions.removeAll()
    }

    /// Record `value` as sent to `key`; false if it's the same as last time.
    private mutating func changed(_ key: SentKey, to value: Int) -> Bool {
        if lastSent[key] == value { return false }
        lastSent[key] = value
        return true
    }

    /// `value_to_midi` in ../impsy/impsy/utils.py for the full 0–127 range.
    private static func midiValue(_ v: Float) -> Int {
        Int(v.clamped(to: 0...1) * 127.0 + 0.5)
    }

    /// A note's output velocity: the first enabled `noteVelocity` dim on its
    /// channel, else the mapping's fixed velocity, else 127.
    private static func velocity(for mapping: DimensionMapping,
                                 outputs: [DimensionMapping],
                                 values: [Float]) -> UInt8 {
        if let index = outputs.firstIndex(where: {
            $0.enabled && $0.messageType == .noteVelocity && $0.channel == mapping.channel
        }), index < values.count {
            // velocity 0 would be a note-off
            return UInt8(max(1, midiValue(values[index])))
        }
        if let fixed = mapping.velocity {
            return UInt8(min(max(fixed, 1), 127))
        }
        return 127
    }

    // MARK: Single-mapping encode (used for UI-driven direct input)

    /// Encode a normalised value (clamped to 0…1) as a MIDI event using the
    /// given mapping. Round-trip safe: feeding the result through
    /// `decodeInput(bytes:length:)` sets the mapping's dimension to a 7-bit
    /// (or 14-bit for pitch bend) quantised approximation of the value.
    ///
    /// A note-on carries both a pitch and a velocity, so `noteOn` and
    /// `noteVelocity` need the other half: `companion` is the normalised
    /// velocity (for `noteOn`) or pitch (for `noteVelocity`). Without one,
    /// a note plays at velocity 127 and a velocity plays note 60.
    static func encode(value: Float, using mapping: DimensionMapping,
                       companion: Float? = nil) -> MIDIEvent {
        let v = max(0, min(1, value))
        let ch = UInt8(mapping.channel - 1) & 0x0F
        switch mapping.messageType {
        case .noteOn:
            // Velocity must be non-zero or decodeInput treats it as note-off.
            let velocity = companion.map { max(1, midiValue($0)) } ?? 127
            return MIDIEvent(0x90 | ch, UInt8(midiValue(v)), UInt8(velocity))
        case .noteVelocity:
            let note = companion.map { midiValue($0) } ?? 60
            return MIDIEvent(0x90 | ch, UInt8(note), UInt8(max(1, midiValue(v))))
        case .controlChange:
            let ccVal = UInt8(min(127, max(0, mapping.denormalize(toCCValue: v))))
            return MIDIEvent(0xB0 | ch, UInt8(mapping.number & 0x7F), ccVal)
        case .pitchBend:
            let raw = Int(v * 16383.0 + 0.5)
            let lsb = UInt8(raw & 0x7F)
            let msb = UInt8((raw >> 7) & 0x7F)
            return MIDIEvent(0xE0 | ch, lsb, msb)
        }
    }

    // MARK: Dense vector helpers

    /// The sparse updates an incoming MIDI event makes to the dense input
    /// vector (length = dimension - 1): 0-based indices and their values.
    func denseUpdate(fromBytes bytes: UnsafePointer<UInt8>, length: Int) -> [(Int, Float)] {
        // convert 1-based dimIDs to 0-based array indices
        decodeInput(bytes: bytes, length: length).map { ($0.0 - 1, $0.1) }
    }
}

// MARK: - Float helpers

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension UInt8 {
    init(clamping value: Int) {
        self = UInt8(Swift.min(Swift.max(value, 0), 127))
    }
}
