import AudioToolbox
import Foundation

// MARK: - AU Parameter Addresses

enum ParameterAddress: AUParameterAddress {
    case threshold  = 0
    case sigmaTemp  = 1
    case piTemp     = 2
    case timescale  = 3
    case inputThru  = 4
}

// MARK: - Parameter Defaults & Ranges

// Defaults from configs/AiC-charles-u6midipro.toml in the IMPSY repository.
enum ParameterDefaults {
    static let threshold: Float  = 0.1
    static let sigmaTemp: Float  = 0.01
    static let piTemp: Float     = 1.0
    static let timescale: Float  = 1.0
    static let inputThru: Float  = 1.0   // on by default
    // Output dedup windows. RNN output for a given dimension is suppressed when
    // it would re-emit the same MIDI value within this window. 0 disables.
    static let dedupNoteWindowMs: Float = 30.0
    static let dedupCCWindowMs:   Float = 30.0
}

enum ParameterRanges {
    static let thresholdMin: Float  = 0.1;  static let thresholdMax: Float  = 10.0
    static let sigmaTempMin: Float  = 0.001; static let sigmaTempMax: Float = 2.0
    static let piTempMin: Float     = 0.1;  static let piTempMax: Float     = 5.0
    static let timescaleMin: Float  = 0.1;  static let timescaleMax: Float  = 4.0
    static let dedupWindowMin: Float = 0.0; static let dedupWindowMax: Float = 500.0
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
    static let inputThru        = "impsy.inputThru"
    static let logFolderBookmark = "impsy.logFolderBookmark" // Data: security-scoped bookmark
    static let logFolderName    = "impsy.logFolderName"      // String: display path
    static let loggingEnabled   = "impsy.loggingEnabled"     // Float: 0/1
    static let dedupNoteWindowMs = "impsy.dedupNoteWindowMs" // Float: 0–500 ms
    static let dedupCCWindowMs   = "impsy.dedupCCWindowMs"   // Float: 0–500 ms (also covers pitch bend)
}

// MARK: - IMPSY Model Constants

enum IMPSYConstants {
    /// All values are multiplied by this before feeding into the model
    static let scaleFactor: Float = 10.0
    /// Minimum time delta (seconds) to prevent division by zero / runaway speed
    static let minimumDeltaTime: Double = 0.000454
    /// Scheduling floor for the response-loop dt, in seconds. Mirrors the
    /// `dt = max(dt, 0.001)` clamp in `../impsy/impsy/interaction.py` (in
    /// `playback_rnn_loop`) — guards against zero/negative dt before the
    /// timescale multiply. Applied before timescale so the model sees the
    /// same floored value it gets scheduled against.
    static let responseLoopMinDt: Double = 0.001
}
