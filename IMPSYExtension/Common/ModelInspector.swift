import Foundation
import TensorFlowLite

// MARK: - Model Configuration

/// Metadata extracted from an IMPSY TFLite model file.
struct ModelConfig: Equatable {
    let dimension:   Int   // total feature dimension (includes time delta at index 0)
    let numLayers:   Int   // number of LSTM layers
    let hiddenUnits: Int   // units per LSTM layer
    let numMixtures: Int   // number of Gaussian mixture components
}

// MARK: - ModelInspector

/// Reads tensor names/shapes from a TFLite file to determine IMPSY model parameters.
///
/// Expected tensor naming (matching IMPSY Python training code):
///   Inputs:  "inputs"          shape (1, 1, dimension)
///            "state_h_0", "state_c_0", "state_h_1", "state_c_1", ...
///   Outputs: MDN output        shape (1, numMixtures*(2*dimension+1))
///            "state_h_0", ... (updated states, same shapes as inputs)
enum ModelInspector {

    enum InspectionError: Error, LocalizedError {
        case failedToLoad(String)
        case missingInputsTensor
        case missingMDNOutput
        case ambiguousDimension

        var errorDescription: String? {
            switch self {
            case .failedToLoad(let msg):    return "Failed to load model: \(msg)"
            case .missingInputsTensor:      return "No 'inputs' tensor found in model"
            case .missingMDNOutput:         return "Could not identify MDN output tensor"
            case .ambiguousDimension:       return "Could not determine model dimension from tensors"
            }
        }
    }

    static func inspect(modelURL: URL) throws -> ModelConfig {
        let interpreter: Interpreter
        do {
            interpreter = try Interpreter(modelPath: modelURL.path)
            try interpreter.allocateTensors()
        } catch {
            throw InspectionError.failedToLoad(error.localizedDescription)
        }

        // ── Find dimension from 'inputs' tensor shape ─────────────────────────
        var dimension: Int? = nil
        var hiddenUnits: Int? = nil
        var numLayers: Int = 0
        var stateIndices: Set<Int> = []

        for i in 0..<interpreter.inputTensorCount {
            guard let tensor = try? interpreter.input(at: i) else { continue }
            let name = tensor.name

            if name == "inputs" || name.hasPrefix("serving_default_inputs") {
                // Shape is (1, 1, dimension)
                guard tensor.shape.dimensions.count == 3 else { continue }
                dimension = tensor.shape.dimensions[2]
            } else if name.contains("state_h") || name.contains("state_c") {
                stateIndices.insert(i)
                if name.contains("state_h"), let units = tensor.shape.dimensions.last {
                    hiddenUnits = units
                }
            }
        }

        // numLayers = number of state_h tensors
        var stateHCount = 0
        for i in 0..<interpreter.inputTensorCount {
            if let tensor = try? interpreter.input(at: i), tensor.name.contains("state_h") {
                stateHCount += 1
            }
        }
        numLayers = max(1, stateHCount)

        guard let dim = dimension else { throw InspectionError.missingInputsTensor }
        guard dim > 1 else { throw InspectionError.ambiguousDimension }

        // ── Find numMixtures from MDN output shape ───────────────────────────
        // MDN output width = numMixtures * (2*dim + 1)
        var numMixtures: Int? = nil
        for i in 0..<interpreter.outputTensorCount {
            guard let tensor = try? interpreter.output(at: i) else { continue }
            // The MDN output is 2D: (1, width) — not a state tensor
            if tensor.shape.dimensions.count == 2,
               let width = tensor.shape.dimensions.last,
               width > dim {
                let candidate = width / (2 * dim + 1)
                if candidate * (2 * dim + 1) == width {
                    numMixtures = candidate
                    break
                }
            }
        }

        guard let mixtures = numMixtures else { throw InspectionError.missingMDNOutput }

        return ModelConfig(
            dimension:   dim,
            numLayers:   numLayers,
            hiddenUnits: hiddenUnits ?? 64,
            numMixtures: mixtures
        )
    }
}
