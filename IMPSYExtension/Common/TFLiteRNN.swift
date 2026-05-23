import Foundation

// MARK: - TFLiteRNN errors (shared across platforms)

enum TFLiteRNNError: Error, LocalizedError {
    case tensorNotFound(String)
    case shapeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .tensorNotFound(let name): return "TFLite tensor '\(name)' not found"
        case .shapeMismatch(let msg):   return "Tensor shape mismatch: \(msg)"
        }
    }
}

#if os(iOS)
import TensorFlowLite

// MARK: - Interpreter warm-up
//
// TFLite does not resolve output tensor shapes until the graph has executed at
// least once. Any code that inspects output tensors (ModelInspector, and
// TFLiteRNN's own tensor discovery) must run this first.

func warmUpInterpreter(_ interpreter: Interpreter) throws {
    for i in 0..<interpreter.inputTensorCount {
        let tensor = try interpreter.input(at: i)
        let count  = tensor.shape.dimensions.reduce(1, *)
        let zeros  = [Float](repeating: 0, count: count)
        let data   = zeros.withUnsafeBufferPointer { Data(buffer: $0) }
        try interpreter.copy(data, toInputAt: i)
    }
    try interpreter.invoke()
}

// MARK: - TFLiteRNN (iOS)
//
// Wraps the TFLite Interpreter for single-step IMPSY MDRNN inference.
//
// NOT thread-safe. Must be called exclusively from the inference serial queue.
//
// Input tensor layout (set each step):
//   "inputs"      shape (1, 1, dimension)    — scaled by SCALE_FACTOR
//   "state_h_N"   shape (1, hiddenUnits)     — LSTM hidden state, layer N
//   "state_c_N"   shape (1, hiddenUnits)     — LSTM cell state, layer N
//
// Output tensor layout (read each step):
//   MDN output    shape (1, numMixtures*(2*dimension+1))
//   "state_h_N"   shape (1, hiddenUnits)     — updated LSTM states
//   "state_c_N"   shape (1, hiddenUnits)

final class TFLiteRNN {

    // MARK: Properties

    private let interpreter: Interpreter
    let config: ModelConfig

    /// Temp file backing the interpreter. TFLite mmaps the model, so the file
    /// has to stay alive for the lifetime of this object.
    private let tempModelURL: URL

    /// LSTM state storage: [layerIndex][h/c (0=h,1=c)][hiddenUnits]
    private var lstmStates: [[[Float]]]

    // Tensor index maps (discovered once during init)
    private var inputsIndex:  Int = -1
    private var stateHInputIndices: [Int] = []   // indexed by layer
    private var stateCInputIndices: [Int] = []
    private var mdnOutputIndex: Int = -1
    private var stateHOutputIndices: [Int] = []
    private var stateCOutputIndices: [Int] = []

    // MARK: Init

    /// Build an RNN from in-memory model bytes.
    ///
    /// The caller (`IMPSYAudioUnit.loadModel`) reads the bytes while the
    /// source URL's security scope is held; from here on we work from a
    /// sandboxed temp file so the engine never depends on the user's URL
    /// still being accessible.
    init(modelData: Data, config: ModelConfig) throws {
        self.config = config
        // Zero-initialise all LSTM states
        let zeroState = [Float](repeating: 0, count: config.hiddenUnits)
        self.lstmStates = (0..<config.numLayers).map { _ in [zeroState, zeroState] }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("impsy-rnn-\(UUID().uuidString).tflite")
        try modelData.write(to: tempURL)
        self.tempModelURL = tempURL

        do {
            let options = Interpreter.Options()
            self.interpreter = try Interpreter(modelPath: tempURL.path, options: options)
            try interpreter.allocateTensors()
            // Output tensor shapes are only valid after the graph has run once.
            try warmUpInterpreter(interpreter)
            try discoverTensorIndices()
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: tempModelURL)
    }

    // MARK: Inference

    /// Run one forward pass.
    ///
    /// - Parameter input: Dense input vector of length `config.dimension`.
    ///   index 0 = time delta, indices 1…N = normalised values.
    ///   These should already be in [0,1] space (no scaling needed here;
    ///   scaling is applied internally).
    /// - Returns: Sampled output vector of length `config.dimension`.
    func generate(input: [Float], piTemp: Float, sigmaTemp: Float) throws -> [Float] {
        // ── Copy scaled inputs ────────────────────────────────────────────────
        let scaledInput = input.map { $0 * IMPSYConstants.scaleFactor }
        let inputData = scaledInput.withUnsafeBufferPointer { Data(buffer: $0) }
        try interpreter.copy(inputData, toInputAt: inputsIndex)

        // ── Copy LSTM states ──────────────────────────────────────────────────
        for layer in 0..<config.numLayers {
            let hData = lstmStates[layer][0].withUnsafeBufferPointer { Data(buffer: $0) }
            let cData = lstmStates[layer][1].withUnsafeBufferPointer { Data(buffer: $0) }
            try interpreter.copy(hData, toInputAt: stateHInputIndices[layer])
            try interpreter.copy(cData, toInputAt: stateCInputIndices[layer])
        }

        // ── Run inference ─────────────────────────────────────────────────────
        try interpreter.invoke()

        // ── Read MDN output ───────────────────────────────────────────────────
        let mdnTensor = try interpreter.output(at: mdnOutputIndex)
        let mdnParams: [Float] = mdnTensor.data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }

        // ── Update LSTM states ────────────────────────────────────────────────
        for layer in 0..<config.numLayers {
            let hTensor = try interpreter.output(at: stateHOutputIndices[layer])
            let cTensor = try interpreter.output(at: stateCOutputIndices[layer])
            lstmStates[layer][0] = hTensor.data.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
            lstmStates[layer][1] = cTensor.data.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
        }

        // ── Sample from MDN output ────────────────────────────────────────────
        return MDNSampler.sample(
            params:     mdnParams,
            dimension:  config.dimension,
            numMixtures: config.numMixtures,
            piTemp:     piTemp,
            sigmaTemp:  sigmaTemp
        )
    }

    /// Reset all LSTM states to zero.
    func resetStates() {
        let zeroState = [Float](repeating: 0, count: config.hiddenUnits)
        for layer in 0..<config.numLayers {
            lstmStates[layer][0] = zeroState
            lstmStates[layer][1] = zeroState
        }
    }

    // MARK: - Tensor Discovery

    private func discoverTensorIndices() throws {
        // ── Input tensors ────────────────────────────────────────────────────
        var hInputByLayer: [Int: Int] = [:]
        var cInputByLayer: [Int: Int] = [:]

        for i in 0..<interpreter.inputTensorCount {
            let tensor = try interpreter.input(at: i)
            let name   = tensor.name
            if name == "inputs" || name.hasSuffix(":0") && name.contains("inputs") || name.contains("serving_default_inputs") {
                inputsIndex = i
            } else if let layer = layerIndex(from: name, prefix: "state_h") {
                hInputByLayer[layer] = i
            } else if let layer = layerIndex(from: name, prefix: "state_c") {
                cInputByLayer[layer] = i
            }
        }

        // Fallback: if tensor names don't match expected patterns, use positional discovery
        if inputsIndex == -1 {
            // First input tensor with 3 dimensions is 'inputs'
            for i in 0..<interpreter.inputTensorCount {
                let tensor = try interpreter.input(at: i)
                if tensor.shape.dimensions.count == 3 {
                    inputsIndex = i
                    break
                }
            }
        }

        guard inputsIndex != -1 else {
            throw TFLiteRNNError.tensorNotFound("inputs")
        }

        // Sort state indices by layer
        stateHInputIndices = (0..<config.numLayers).map { hInputByLayer[$0] ?? -1 }
        stateCInputIndices = (0..<config.numLayers).map { cInputByLayer[$0] ?? -1 }

        // Fallback for state tensors: assign remaining 2D tensors in order
        if stateHInputIndices.contains(-1) {
            var stateTensors: [Int] = []
            for i in 0..<interpreter.inputTensorCount {
                if i == inputsIndex { continue }
                let tensor = try interpreter.input(at: i)
                if tensor.shape.dimensions.count == 2 {
                    stateTensors.append(i)
                }
            }
            // Expected: [h0, c0, h1, c1, ...]
            stateHInputIndices = stride(from: 0, to: stateTensors.count, by: 2).map { stateTensors[$0] }
            stateCInputIndices = stride(from: 1, to: stateTensors.count, by: 2).map { stateTensors[$0] }
        }

        // ── Output tensors ───────────────────────────────────────────────────
        var hOutputByLayer: [Int: Int] = [:]
        var cOutputByLayer: [Int: Int] = [:]

        for i in 0..<interpreter.outputTensorCount {
            let tensor = try interpreter.output(at: i)
            let name   = tensor.name
            if let layer = layerIndex(from: name, prefix: "state_h") {
                hOutputByLayer[layer] = i
            } else if let layer = layerIndex(from: name, prefix: "state_c") {
                cOutputByLayer[layer] = i
            } else if tensor.shape.dimensions.count == 2,
                      let width = tensor.shape.dimensions.last,
                      width == config.numMixtures * (2 * config.dimension + 1) {
                mdnOutputIndex = i
            }
        }

        if mdnOutputIndex == -1 {
            // Fallback: largest output tensor by element count
            var maxCount = 0
            for i in 0..<interpreter.outputTensorCount {
                let tensor = try interpreter.output(at: i)
                let count  = tensor.shape.dimensions.reduce(1, *)
                if count > maxCount { maxCount = count; mdnOutputIndex = i }
            }
        }

        guard mdnOutputIndex != -1 else {
            throw TFLiteRNNError.tensorNotFound("MDN output")
        }

        stateHOutputIndices = (0..<config.numLayers).map { hOutputByLayer[$0] ?? -1 }
        stateCOutputIndices = (0..<config.numLayers).map { cOutputByLayer[$0] ?? -1 }

        // Fallback for output state tensors
        if stateHOutputIndices.contains(-1) {
            var stateTensors: [Int] = []
            for i in 0..<interpreter.outputTensorCount {
                if i == mdnOutputIndex { continue }
                let tensor = try interpreter.output(at: i)
                if tensor.shape.dimensions.count == 2 {
                    stateTensors.append(i)
                }
            }
            stateHOutputIndices = stride(from: 0, to: stateTensors.count, by: 2).map { stateTensors[$0] }
            stateCOutputIndices = stride(from: 1, to: stateTensors.count, by: 2).map { stateTensors[$0] }
        }
    }

    /// Parses "state_h_2" → 2, "state_c_0" → 0, etc.
    private func layerIndex(from name: String, prefix: String) -> Int? {
        guard name.contains(prefix) else { return nil }
        let parts = name.components(separatedBy: "_")
        if let last = parts.last, let n = Int(last) { return n }
        return 0   // single-layer fallback
    }
}

#else

// MARK: - TFLiteRNN (macOS stub — TFLite xcframework is iOS-only)

final class TFLiteRNN {
    let config: ModelConfig

    init(modelData: Data, config: ModelConfig) throws {
        self.config = config
        throw TFLiteRNNError.tensorNotFound("TFLite inference is not available on macOS")
    }

    func generate(input: [Float], piTemp: Float, sigmaTemp: Float) throws -> [Float] {
        throw TFLiteRNNError.tensorNotFound("TFLite inference is not available on macOS")
    }

    func resetStates() {}
}

#endif
