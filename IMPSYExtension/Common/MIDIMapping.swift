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

    static func defaults(forDimension index: Int) -> DimensionMapping {
        DimensionMapping(
            id: index,
            messageType: .controlChange,
            channel: 1,
            number: max(0, min(127, 73 + index))   // CC 74, 75, 76...
        )
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
