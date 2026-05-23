import Foundation

// MARK: - MIDI Message Type

enum MIDIMessageType: String, Codable, CaseIterable {
    case noteOn        = "noteOn"
    case controlChange = "controlChange"
    case pitchBend     = "pitchBend"

    var displayName: String {
        switch self {
        case .noteOn:        return "Note On"
        case .controlChange: return "CC"
        case .pitchBend:     return "Pitch Bend"
        }
    }

    /// Whether this type uses a "number" field (note number or CC number)
    var usesNumber: Bool {
        switch self {
        case .noteOn, .controlChange: return true
        case .pitchBend:              return false
        }
    }
}

// MARK: - Dimension Mapping

/// Maps one IMPSY dimension (1-based; dimension 0 is always time delta) to a MIDI message.
struct DimensionMapping: Codable, Identifiable, Equatable {
    /// Dimension index (1-based, matching model output index)
    var id: Int
    var messageType: MIDIMessageType
    /// MIDI channel (1–16)
    var channel: Int
    /// Note number (0–127) for noteOn, CC number (0–127) for controlChange; ignored for pitchBend
    var number: Int
    /// Lower bound of the CC range (0–127). Currently only consulted for
    /// `controlChange` — matches IMPSY's 5-tuple TOML form
    /// `["control_change", ch, cc, min, max]`.
    var minValue: Int = 0
    /// Upper bound of the CC range (0–127).
    var maxValue: Int = 127

    static func defaults(forDimension index: Int) -> DimensionMapping {
        DimensionMapping(
            id: index,
            messageType: .controlChange,
            channel: 1,
            number: max(0, min(127, 73 + index))   // CC 74, 75, 76...
        )
    }

    // MARK: - Codable
    //
    // Custom decode lets older persisted state (fullState dictionaries written
    // before min/max existed) round-trip without breaking — missing fields
    // fall back to the full 0–127 range.

    private enum CodingKeys: String, CodingKey {
        case id, messageType, channel, number, minValue, maxValue
    }

    init(id: Int,
         messageType: MIDIMessageType,
         channel: Int,
         number: Int,
         minValue: Int = 0,
         maxValue: Int = 127) {
        self.id = id
        self.messageType = messageType
        self.channel = channel
        self.number = number
        self.minValue = minValue
        self.maxValue = maxValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(Int.self, forKey: .id)
        messageType = try c.decode(MIDIMessageType.self, forKey: .messageType)
        channel     = try c.decode(Int.self, forKey: .channel)
        number      = try c.decode(Int.self, forKey: .number)
        minValue    = try c.decodeIfPresent(Int.self, forKey: .minValue) ?? 0
        maxValue    = try c.decodeIfPresent(Int.self, forKey: .maxValue) ?? 127
    }
}

extension DimensionMapping {
    /// Map a 7-bit MIDI CC value through this mapping's min/max range into
    /// the model's normalised [0, 1] space.
    func normalize(ccValue raw: Int) -> Float {
        let span = maxValue - minValue
        guard span != 0 else { return 0 }
        let clamped = max(minValue, min(maxValue, raw))
        return Float(clamped - minValue) / Float(span)
    }

    /// Map a normalised [0, 1] value through this mapping's min/max range to
    /// an integer 7-bit MIDI CC value (clamped to 0…127).
    func denormalize(toCCValue v: Float) -> Int {
        let clamped = max(0, min(1, v))
        let scaled = Float(minValue) + clamped * Float(maxValue - minValue)
        return max(0, min(127, Int((scaled).rounded())))
    }
}

// MARK: - Mapping Set

/// Full input + output mapping for all model dimensions.
struct MIDIMappingSet: Codable, Equatable {
    /// One entry per model dimension (excluding dim 0 which is time).
    /// Index 0 = dimension 1, index 1 = dimension 2, etc.
    var inputMappings:  [DimensionMapping]
    var outputMappings: [DimensionMapping]

    /// Build a default mapping set for a model with `dimension` total dims (including time).
    static func defaults(forModelDimension dimension: Int) -> MIDIMappingSet {
        let count = max(0, dimension - 1)
        return MIDIMappingSet(
            inputMappings:  (1...max(1, count)).map { DimensionMapping.defaults(forDimension: $0) },
            outputMappings: (1...max(1, count)).map { DimensionMapping.defaults(forDimension: $0) }
        )
    }

    /// Default mapping for the bundled 9-dimension IMPSY model, ported from
    /// `configs/AiC-charles-u6midipro.toml` in the IMPSY repository.
    ///
    /// Input  — eight nanoKONTROL Studio knobs: CC 13–20 on channel 1.
    /// Output — alternating note / CC pairs: note_on on channels 1–4,
    ///          control_change CC 1–4 on channel 11.
    static func aicU6MIDIProDefault() -> MIDIMappingSet {
        let input: [DimensionMapping] = (0..<8).map { i in
            DimensionMapping(id: i + 1, messageType: .controlChange,
                             channel: 1, number: 13 + i)
        }
        // Output dimensions interleave note_on and control_change.
        let output: [DimensionMapping] = (0..<8).map { i in
            if i.isMultiple(of: 2) {
                // dims 1,3,5,7 → note_on on channels 1,2,3,4
                return DimensionMapping(id: i + 1, messageType: .noteOn,
                                        channel: i / 2 + 1, number: 60)
            } else {
                // dims 2,4,6,8 → control_change CC 1,2,3,4 on channel 11
                return DimensionMapping(id: i + 1, messageType: .controlChange,
                                        channel: 11, number: i / 2 + 1)
            }
        }
        return MIDIMappingSet(inputMappings: input, outputMappings: output)
    }

    /// Resize mappings to match a new model dimension, preserving existing entries.
    mutating func resize(toModelDimension dimension: Int) {
        let count = max(0, dimension - 1)
        while inputMappings.count < count {
            inputMappings.append(.defaults(forDimension: inputMappings.count + 1))
        }
        while outputMappings.count < count {
            outputMappings.append(.defaults(forDimension: outputMappings.count + 1))
        }
        if inputMappings.count > count  { inputMappings  = Array(inputMappings.prefix(count)) }
        if outputMappings.count > count { outputMappings = Array(outputMappings.prefix(count)) }
    }
}
