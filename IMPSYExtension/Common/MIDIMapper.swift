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
        var bytes: [UInt8] = [statusByte, data1, data2]
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
struct MIDIMapper {

    var mappings: MIDIMappingSet

    // Last note_on number emitted per output channel (0–15). Used to insert a
    // note_off for the previous note before each new note_on so each channel
    // behaves monophonically — matching IMPSY's reference impsio behaviour
    // (../impsy/impsy/impsio.py: note_off-before-note_on per channel).
    private var lastNotes: [UInt8: UInt8] = [:]

    init(mappings: MIDIMappingSet) {
        self.mappings = mappings
    }

    // MARK: Decode (MIDI → normalised value)

    /// Given raw MIDI bytes, returns `(dimensionIndex, normalizedValue)` if the message
    /// matches any input mapping, or `nil` otherwise.
    /// `dimensionIndex` is 1-based (matches model dimensions 1…N).
    func decodeInput(bytes: UnsafePointer<UInt8>, length: Int) -> (Int, Float)? {
        guard length >= 2 else { return nil }
        let status = bytes[0]
        let messageType = status & 0xF0
        let channel = Int(status & 0x0F) + 1

        for mapping in mappings.inputMappings {
            guard mapping.channel == channel else { continue }
            switch mapping.messageType {
            case .noteOn:
                guard messageType == 0x90, bytes[1] == UInt8(mapping.number) else { continue }
                let velocity = length >= 3 ? bytes[2] : 0
                return (mapping.id, Float(velocity) / 127.0)
            case .controlChange:
                guard messageType == 0xB0, bytes[1] == UInt8(mapping.number) else { continue }
                let value = length >= 3 ? bytes[2] : 0
                return (mapping.id, mapping.normalize(ccValue: Int(value)))
            case .pitchBend:
                guard messageType == 0xE0 else { continue }
                let lsb = length >= 2 ? Int(bytes[1]) : 0
                let msb = length >= 3 ? Int(bytes[2]) : 0
                let raw = (msb << 7) | lsb   // 0–16383
                return (mapping.id, Float(raw) / 16383.0)
            }
        }
        return nil
    }

    // MARK: Encode (normalised value → MIDI)

    /// Given a model output vector (index 0 = dim 1), produce MIDI events for each dimension.
    /// `values` is 0-based: values[0] → dimension 1, values[1] → dimension 2, etc.
    ///
    /// For note_on outputs, a note_off for the previously emitted note on the
    /// same channel is inserted before the new note_on, keeping each channel
    /// monophonic.
    mutating func encodeOutput(values: [Float]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        for (i, mapping) in mappings.outputMappings.enumerated() {
            guard i < values.count else { break }
            let v = values[i].clamped(to: 0...1)
            let ch = UInt8(mapping.channel - 1) & 0x0F

            switch mapping.messageType {
            case .noteOn:
                let note = UInt8(clamping: Int(v * 127.0 + 0.5))
                if let previous = lastNotes[ch] {
                    events.append(MIDIEvent(0x80 | ch, previous, 0))
                }
                events.append(MIDIEvent(0x90 | ch, note, 64))
                lastNotes[ch] = note
            case .controlChange:
                let ccVal = UInt8(clamping: mapping.denormalize(toCCValue: v))
                events.append(MIDIEvent(0xB0 | ch, UInt8(mapping.number & 0x7F), ccVal))
            case .pitchBend:
                let raw = Int(v * 16383.0 + 0.5)
                let lsb = UInt8(raw & 0x7F)
                let msb = UInt8((raw >> 7) & 0x7F)
                events.append(MIDIEvent(0xE0 | ch, lsb, msb))
            }
        }
        return events
    }

    /// Emit a note_off for every channel that currently has an outstanding
    /// note_on, then forget them. Call at mode/model transitions so that the
    /// last RNN-emitted note does not hang on the receiving synth.
    mutating func releaseAllNotes() -> [MIDIEvent] {
        let offs = lastNotes.map { ch, note in
            MIDIEvent(0x80 | ch, note, 0)
        }
        lastNotes.removeAll()
        return offs
    }

    // MARK: Single-mapping encode (used for UI-driven direct input)

    /// Encode a normalised value (clamped to 0…1) as a MIDI event using the
    /// given mapping. Round-trip safe: feeding the result through
    /// `decodeInput(bytes:length:)` returns the same dimension and a 7-bit
    /// (or 14-bit for pitch bend) quantised approximation of the value.
    static func encode(value: Float, using mapping: DimensionMapping) -> MIDIEvent {
        let v = max(0, min(1, value))
        let ch = UInt8(mapping.channel - 1) & 0x0F
        switch mapping.messageType {
        case .noteOn:
            let note = UInt8(mapping.number & 0x7F)
            // Velocity carries the value so decodeInput recovers it.
            let vel = UInt8(min(127, max(0, Int(v * 127.0 + 0.5))))
            return MIDIEvent(0x90 | ch, note, vel)
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

    /// Build a dense input vector (length = dimension - 1) from an incoming MIDI event.
    /// Returns a sparse update: only the affected dimension index (0-based) and its value.
    func denseUpdate(fromBytes bytes: UnsafePointer<UInt8>, length: Int) -> (Int, Float)? {
        guard let (dimID, value) = decodeInput(bytes: bytes, length: length) else { return nil }
        return (dimID - 1, value)   // convert 1-based dimID to 0-based array index
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
