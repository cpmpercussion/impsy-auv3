import Foundation
import AudioToolbox
import Combine

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Model Status

enum ModelStatus: Equatable {
    case noModel
    case loading
    case ready(ModelConfig)
    case error(String)

    var displayString: String {
        switch self {
        case .noModel:        return "No model loaded"
        case .loading:        return "Loading..."
        case .ready(let cfg): return "Ready · dim:\(cfg.dimension) layers:\(cfg.numLayers) units:\(cfg.hiddenUnits)"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - IMPSYViewModel

@MainActor
final class IMPSYViewModel: ObservableObject {

    // MARK: - Published

    @Published var modelName:  String = "No model loaded"
    @Published var modelStatus: ModelStatus = .noModel
    @Published var mappings: MIDIMappingSet = .defaults(forModelDimension: 2)
    @Published var callResponseState: String = "CALL"

    // Live activity feedback from the call-and-response loop
    @Published var generatedEventCount: Int = 0
    @Published var inputEventCount: Int = 0
    @Published var lastEventSummary: String = "—"
    @Published var lastEventDt: Double = 0

    // Per-dimension activity (one counter per user dimension, 0-based index =
    // dim 1 .. dim N). Incremented every time that dimension sees activity so
    // the dashboard can flash a per-channel indicator without re-renders for
    // unrelated state.
    @Published var inputDimensionCounts: [Int] = []
    @Published var outputDimensionCounts: [Int] = []

    // Last normalised value the RNN produced for each output dimension. Drives
    // the dashboard's bidirectional faders: idle, the fader follows the model;
    // when dragged, it sets these and injects MIDI as if the configured input
    // message had arrived.
    @Published var outputValues: [Float] = []

    // Parameter values (two-way bound to AUParameterTree)
    @Published var threshold: Float = ParameterDefaults.threshold
    @Published var sigmaTemp: Float = ParameterDefaults.sigmaTemp
    @Published var piTemp:    Float = ParameterDefaults.piTemp
    @Published var timescale: Float = ParameterDefaults.timescale
    @Published var inputThru: Bool  = ParameterDefaults.inputThru > 0.5

    // MARK: - Audio Unit reference

    weak var audioUnit: IMPSYAudioUnit? {
        didSet { connectToAudioUnit() }
    }

    // MARK: - Parameter observation tokens

    private var paramObserverToken: AUParameterObserverToken?
    private var notificationTokens: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        setupParameterSync()
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Connections

    private func connectToAudioUnit() {
        guard let au = audioUnit else { return }

        // Sync initial state
        if let tree = au.parameterTree {
            threshold = tree.parameter(withAddress: ParameterAddress.threshold.rawValue)?.value ?? ParameterDefaults.threshold
            sigmaTemp = tree.parameter(withAddress: ParameterAddress.sigmaTemp.rawValue)?.value ?? ParameterDefaults.sigmaTemp
            piTemp    = tree.parameter(withAddress: ParameterAddress.piTemp.rawValue)?.value    ?? ParameterDefaults.piTemp
            timescale = tree.parameter(withAddress: ParameterAddress.timescale.rawValue)?.value ?? ParameterDefaults.timescale
            inputThru = (tree.parameter(withAddress: ParameterAddress.inputThru.rawValue)?.value ?? ParameterDefaults.inputThru) > 0.5

            // Observe parameter changes from host automation
            paramObserverToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
                DispatchQueue.main.async {
                    guard let self, let addr = ParameterAddress(rawValue: address) else { return }
                    switch addr {
                    case .threshold: self.threshold = value
                    case .sigmaTemp: self.sigmaTemp = value
                    case .piTemp:    self.piTemp    = value
                    case .timescale: self.timescale = value
                    case .inputThru: self.inputThru = value > 0.5
                    }
                }
            })
        }

        // Sync current model state
        if let config = au.currentModelConfig {
            modelName   = au.currentModelDisplayName ?? "Unknown"
            modelStatus = .ready(config)
            mappings    = au.currentMappings
            resizeDimensionCounts(toModelDimension: config.dimension)
        }

        // Sync the current call/response state (the engine may already be running)
        callResponseState = au.engine.callResponseState.rawValue

        // Listen for model status changes
        let modelToken = NotificationCenter.default.addObserver(
            forName: .IMPSYModelStatusChanged,
            object: au,
            queue: .main
        ) { [weak self] note in
            self?.handleModelStatusNotification(note)
        }

        // Listen for call-response state changes
        let stateToken = NotificationCenter.default.addObserver(
            forName: .IMPSYCallResponseStateChanged,
            object: au,
            queue: .main
        ) { [weak self] note in
            self?.callResponseState = (note.userInfo?["state"] as? String) ?? "CALL"
        }

        // Listen for generated events (live activity feedback)
        let eventToken = NotificationCenter.default.addObserver(
            forName: .IMPSYEventGenerated,
            object: au,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.generatedEventCount += 1
            self.lastEventSummary = (note.userInfo?["summary"] as? String) ?? "—"
            self.lastEventDt = (note.userInfo?["dt"] as? Double) ?? 0
            if let dims = note.userInfo?["dimensions"] as? [Int] {
                for dim in dims where self.outputDimensionCounts.indices.contains(dim) {
                    self.outputDimensionCounts[dim] += 1
                }
            }
            if let values = note.userInfo?["values"] as? [Float] {
                for (i, v) in values.enumerated()
                    where self.outputValues.indices.contains(i) {
                    self.outputValues[i] = v
                }
            }
        }

        // Listen for inbound user MIDI events (red ACT LED + per-dim flash)
        let inputToken = NotificationCenter.default.addObserver(
            forName: .IMPSYUserInputReceived,
            object: au,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.inputEventCount += 1
            if let dim = note.userInfo?["dimension"] as? Int,
               self.inputDimensionCounts.indices.contains(dim) {
                self.inputDimensionCounts[dim] += 1
            }
        }

        notificationTokens = [modelToken, stateToken, eventToken, inputToken]
    }

    private func handleModelStatusNotification(_ note: Notification) {
        guard let info = note.userInfo,
              let status = info["status"] as? String else { return }

        switch status {
        case "ready":
            if let config = info["config"] as? ModelConfig {
                modelStatus = .ready(config)
                modelName   = (info["name"] as? String) ?? modelName
                var updated = mappings
                updated.resize(toModelDimension: config.dimension)
                mappings = updated
                resizeDimensionCounts(toModelDimension: config.dimension)
            }
        case "error":
            modelStatus = .error((info["message"] as? String) ?? "Unknown error")
        default:
            break
        }
    }

    // MARK: - Per-dimension activity sizing

    /// Resize input/output activity counters and the fader value array to
    /// match the model's user dimensions (dim 0 is dt and is not user-mapped,
    /// so we use dimension - 1).
    private func resizeDimensionCounts(toModelDimension dimension: Int) {
        let userDims = max(0, dimension - 1)
        if inputDimensionCounts.count != userDims {
            inputDimensionCounts = Array(repeating: 0, count: userDims)
        }
        if outputDimensionCounts.count != userDims {
            outputDimensionCounts = Array(repeating: 0, count: userDims)
        }
        if outputValues.count != userDims {
            outputValues = Array(repeating: 0, count: userDims)
        }
    }

    // MARK: - Parameter Sync (UI → AU)

    private func setupParameterSync() {
        // Sync slider changes to AU parameter tree
        $threshold.dropFirst().sink { [weak self] val in self?.setParameter(.threshold, value: val) }.store(in: &cancellables)
        $sigmaTemp.dropFirst().sink { [weak self] val in self?.setParameter(.sigmaTemp, value: val) }.store(in: &cancellables)
        $piTemp.dropFirst().sink    { [weak self] val in self?.setParameter(.piTemp,    value: val) }.store(in: &cancellables)
        $timescale.dropFirst().sink { [weak self] val in self?.setParameter(.timescale, value: val) }.store(in: &cancellables)
        $inputThru.dropFirst().sink { [weak self] on  in self?.setParameter(.inputThru, value: on ? 1 : 0) }.store(in: &cancellables)
    }

    private func setParameter(_ address: ParameterAddress, value: Float) {
        audioUnit?.parameterTree?.parameter(withAddress: address.rawValue)?.setValue(value, originator: paramObserverToken)
    }

    // MARK: - Actions

    func loadModel(url: URL) {
        modelStatus = .loading
        modelName   = url.lastPathComponent
        audioUnit?.loadModel(url: url)
    }

    func saveMappings() {
        audioUnit?.currentMappings = mappings
    }

    func resetLSTM() {
        audioUnit?.engine.resetLSTMStates()
    }

    /// Inject a normalised value (0…1) for a user input dimension as if the
    /// configured MIDI message had just arrived for it. Used by the dashboard
    /// faders so dragging drives the same input pipeline as real MIDI in.
    func injectInput(dimensionIndex: Int, value: Float) {
        guard mappings.inputMappings.indices.contains(dimensionIndex),
              let buffer = audioUnit?.engine.inputBuffer else { return }
        let mapping = mappings.inputMappings[dimensionIndex]
        let event = MIDIMapper.encode(value: value, using: mapping)
        buffer.enqueue(RawMIDIPacket(event.statusByte, event.data1, event.data2,
                                     length: event.byteCount))
    }
}
