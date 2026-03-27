import AudioToolbox
import Foundation

// MARK: - AU Parameter Addresses

enum ParameterAddress: AUParameterAddress {
    case threshold  = 0
    case sigmaTemp  = 1
    case piTemp     = 2
    case timescale  = 3
}

// MARK: - Parameter Defaults & Ranges

enum ParameterDefaults {
    static let threshold: Float  = 2.0
    static let sigmaTemp: Float  = 0.01
    static let piTemp: Float     = 1.5
    static let timescale: Float  = 1.0
}

enum ParameterRanges {
    static let thresholdMin: Float  = 0.1;  static let thresholdMax: Float  = 10.0
    static let sigmaTempMin: Float  = 0.001; static let sigmaTempMax: Float = 2.0
    static let piTempMin: Float     = 0.1;  static let piTempMax: Float     = 5.0
    static let timescaleMin: Float  = 0.1;  static let timescaleMax: Float  = 4.0
}

// MARK: - fullState Keys

enum StateKey {
    static let modelBookmark    = "impsy.modelBookmark"   // Data: security-scoped bookmark
    static let modelURLString   = "impsy.modelURL"         // String: display path
    static let inputMappings    = "impsy.inputMappings"    // Data: JSON [DimensionMapping]
    static let outputMappings   = "impsy.outputMappings"   // Data: JSON [DimensionMapping]
    static let threshold        = "impsy.threshold"
    static let sigmaTemp        = "impsy.sigmaTemp"
    static let piTemp           = "impsy.piTemp"
    static let timescale        = "impsy.timescale"
}

// MARK: - IMPSY Model Constants

enum IMPSYConstants {
    /// All values are multiplied by this before feeding into the model
    static let scaleFactor: Float = 10.0
    /// Minimum time delta (seconds) to prevent division by zero / runaway speed
    static let minimumDeltaTime: Double = 0.000454
}
