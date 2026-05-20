import AudioToolbox
import Foundation

// MARK: - IMPSYAudioUnit State Persistence
//
// `fullState` is serialized by the host when saving sessions.
// Non-parameter state (model path, MIDI mappings) lives here.
// The four AU parameters are additionally in the AUParameterTree
// (the host reads those separately).

extension IMPSYAudioUnit {

    // MARK: - Stored non-parameter state (backing storage lives in IMPSYAudioUnit.swift)

    /// Security-scoped bookmark for the loaded model file.
    /// Persisted across sessions; resolved on fullState restore.
    var modelBookmarkData: Data? {
        get { _modelBookmarkData }
        set {
            _modelBookmarkData = newValue
            if let data = newValue {
                resolveAndLoadModel(from: data)
            }
        }
    }

    var currentMappings: MIDIMappingSet {
        get { _currentMappings }
        set {
            _currentMappings = newValue
            engine.updateMappings(newValue)
        }
    }

    var currentModelConfig: ModelConfig? { _currentModelConfig }

    var currentModelDisplayName: String? { _currentModelDisplayName }

    // MARK: - fullState Override

    public override var fullState: [String: Any]? {
        get { buildFullState() }
        set { restoreFullState(newValue) }
    }

    public override var fullStateForDocument: [String: Any]? {
        get { fullState }
        set { fullState = newValue }
    }

    // MARK: - Model Loading (public API for UI)

    /// Load a model from a user-selected URL.
    /// Persists a security-scoped bookmark so the model survives session restore.
    func loadModel(url: URL) {
        // Access must be started before creating the bookmark
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            #if os(macOS)
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif

            let config = try ModelInspector.inspect(modelURL: url)
            _currentModelConfig       = config
            _currentModelDisplayName  = url.lastPathComponent
            _modelBookmarkData        = bookmark

            // Resize mappings to match new dimension
            var updated = _currentMappings
            updated.resize(toModelDimension: config.dimension)
            _currentMappings = updated
            engine.updateMappings(updated)

            engine.loadModel(url: url, config: config)

            NotificationCenter.default.post(name: .IMPSYModelStatusChanged, object: self,
                                            userInfo: ["status": "ready",
                                                       "config": config,
                                                       "name": url.lastPathComponent])
        } catch {
            NotificationCenter.default.post(name: .IMPSYModelStatusChanged, object: self,
                                            userInfo: ["status": "error", "message": error.localizedDescription])
        }
    }

    // MARK: - Bundled Default Model

    static let defaultModelName = "musicMDRNN-dim9-layers2-units64-mixtures5-scale10"

    /// Loads the bundled default 9D model from the extension's resource bundle.
    func loadBundledDefaultModel() {
        let bundle = Bundle(for: IMPSYAudioUnit.self)
        guard let url = bundle.url(forResource: Self.defaultModelName, withExtension: "tflite") else {
            NSLog("[IMPSY] Bundled model '%@.tflite' not found in %@",
                  Self.defaultModelName, bundle.bundlePath)
            NotificationCenter.default.post(name: .IMPSYModelStatusChanged, object: self,
                                            userInfo: ["status": "error",
                                                       "message": "Bundled model not found in app bundle"])
            return
        }
        do {
            let config = try ModelInspector.inspect(modelURL: url)
            _currentModelConfig      = config
            _currentModelDisplayName = url.lastPathComponent
            // The bundled model is the 9-dimension MDRNN; give it the AiC
            // U6MIDI Pro mapping by default. Other dimensions fall back to
            // generic per-dimension defaults.
            var updated = config.dimension == 9
                ? MIDIMappingSet.aicU6MIDIProDefault()
                : _currentMappings
            updated.resize(toModelDimension: config.dimension)
            _currentMappings = updated
            engine.updateMappings(updated)
            engine.loadModel(url: url, config: config)
            NSLog("[IMPSY] Loaded bundled model %@ (dim=%d layers=%d units=%d mixtures=%d)",
                  url.lastPathComponent, config.dimension, config.numLayers,
                  config.hiddenUnits, config.numMixtures)
            NotificationCenter.default.post(name: .IMPSYModelStatusChanged, object: self,
                                            userInfo: ["status": "ready",
                                                       "config": config,
                                                       "name": url.lastPathComponent])
        } catch {
            NSLog("[IMPSY] Failed to load bundled model: %@", String(describing: error))
            NotificationCenter.default.post(name: .IMPSYModelStatusChanged, object: self,
                                            userInfo: ["status": "error",
                                                       "message": error.localizedDescription])
        }
    }

    // MARK: - Private Helpers

    private func buildFullState() -> [String: Any] {
        var state: [String: Any] = [:]

        if let bookmark = _modelBookmarkData {
            state[StateKey.modelBookmark] = bookmark
        }
        if let name = _currentModelDisplayName {
            state[StateKey.modelURLString] = name
        }

        if let inputData  = try? JSONEncoder().encode(_currentMappings.inputMappings) {
            state[StateKey.inputMappings] = inputData
        }
        if let outputData = try? JSONEncoder().encode(_currentMappings.outputMappings) {
            state[StateKey.outputMappings] = outputData
        }

        state[StateKey.threshold] = Float(engine.threshold)
        state[StateKey.sigmaTemp] = engine.sigmaTemp
        state[StateKey.piTemp]    = engine.piTemp
        state[StateKey.timescale] = engine.timescale

        return state
    }

    private func restoreFullState(_ state: [String: Any]?) {
        guard let state else { return }

        // Restore parameters
        if let v = state[StateKey.threshold] as? Float {
            engine.threshold = Double(v)
            parameterTree_?[ParameterAddress.threshold.rawValue]?.value = v
        }
        if let v = state[StateKey.sigmaTemp] as? Float {
            engine.sigmaTemp = v
            parameterTree_?[ParameterAddress.sigmaTemp.rawValue]?.value = v
        }
        if let v = state[StateKey.piTemp] as? Float {
            engine.piTemp = v
            parameterTree_?[ParameterAddress.piTemp.rawValue]?.value = v
        }
        if let v = state[StateKey.timescale] as? Float {
            engine.timescale = v
            parameterTree_?[ParameterAddress.timescale.rawValue]?.value = v
        }

        // Restore MIDI mappings
        var restoredMappings = _currentMappings
        if let data = state[StateKey.inputMappings] as? Data,
           let decoded = try? JSONDecoder().decode([DimensionMapping].self, from: data) {
            restoredMappings.inputMappings = decoded
        }
        if let data = state[StateKey.outputMappings] as? Data,
           let decoded = try? JSONDecoder().decode([DimensionMapping].self, from: data) {
            restoredMappings.outputMappings = decoded
        }
        _currentMappings = restoredMappings
        engine.updateMappings(restoredMappings)

        // Restore display name
        _currentModelDisplayName = state[StateKey.modelURLString] as? String

        // Restore model from bookmark, or fall back to bundled default
        if let bookmark = state[StateKey.modelBookmark] as? Data {
            _modelBookmarkData = bookmark
            resolveAndLoadModel(from: bookmark)
        } else {
            loadBundledDefaultModel()
        }
    }

    private func resolveAndLoadModel(from bookmarkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var isStale = false
                #if os(macOS)
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                #else
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: [],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                #endif

                let accessing = url.startAccessingSecurityScopedResource()
                let config = try ModelInspector.inspect(modelURL: url)
                self?._currentModelConfig = config
                self?.engine.loadModel(url: url, config: config)
                if accessing { url.stopAccessingSecurityScopedResource() }

                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .IMPSYModelStatusChanged,
                                                    object: self,
                                                    userInfo: ["status": "ready",
                                                               "config": config,
                                                               "name": url.lastPathComponent])
                }
            } catch {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .IMPSYModelStatusChanged,
                                                    object: self,
                                                    userInfo: ["status": "error",
                                                               "message": error.localizedDescription])
                }
            }
        }
    }
}

// MARK: - AUParameterTree subscript helper

private extension AUParameterTree {
    subscript(address: AUParameterAddress) -> AUParameter? {
        parameter(withAddress: address)
    }
}
