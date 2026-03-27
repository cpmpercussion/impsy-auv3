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

    // Parameter values (two-way bound to AUParameterTree)
    @Published var threshold: Float = ParameterDefaults.threshold
    @Published var sigmaTemp: Float = ParameterDefaults.sigmaTemp
    @Published var piTemp:    Float = ParameterDefaults.piTemp
    @Published var timescale: Float = ParameterDefaults.timescale

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

            // Observe parameter changes from host automation
            paramObserverToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
                DispatchQueue.main.async {
                    guard let self, let addr = ParameterAddress(rawValue: address) else { return }
                    switch addr {
                    case .threshold: self.threshold = value
                    case .sigmaTemp: self.sigmaTemp = value
                    case .piTemp:    self.piTemp    = value
                    case .timescale: self.timescale = value
                    }
                }
            })
        }

        // Sync current model state
        if let config = au.currentModelConfig {
            modelName   = au.currentModelDisplayName ?? "Unknown"
            modelStatus = .ready(config)
            mappings    = au.currentMappings
        }

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

        notificationTokens = [modelToken, stateToken]
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
            }
        case "error":
            modelStatus = .error((info["message"] as? String) ?? "Unknown error")
        default:
            break
        }
    }

    // MARK: - Parameter Sync (UI → AU)

    private func setupParameterSync() {
        // Sync slider changes to AU parameter tree
        $threshold.dropFirst().sink { [weak self] val in self?.setParameter(.threshold, value: val) }.store(in: &cancellables)
        $sigmaTemp.dropFirst().sink { [weak self] val in self?.setParameter(.sigmaTemp, value: val) }.store(in: &cancellables)
        $piTemp.dropFirst().sink    { [weak self] val in self?.setParameter(.piTemp,    value: val) }.store(in: &cancellables)
        $timescale.dropFirst().sink { [weak self] val in self?.setParameter(.timescale, value: val) }.store(in: &cancellables)
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
}
