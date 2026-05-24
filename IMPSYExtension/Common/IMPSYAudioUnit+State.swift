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

    // MARK: - Session Logging (public API for UI)

    /// Currently selected logs folder (display path). `nil` if the user has
    /// not picked one yet.
    var logFolderDisplayPath: String? { _logFolderDisplayPath }

    /// Output dedup window for note_on events, in milliseconds. Setting writes
    /// through to the engine so the response-loop encode picks up the change
    /// on its next tick.
    var dedupNoteWindowMs: Float {
        get { _dedupNoteWindowMs }
        set {
            _dedupNoteWindowMs = newValue
            engine.dedupNoteWindowMs = newValue
        }
    }

    /// Output dedup window for CC and pitch bend events, in milliseconds.
    var dedupCCWindowMs: Float {
        get { _dedupCCWindowMs }
        set {
            _dedupCCWindowMs = newValue
            engine.dedupCCWindowMs = newValue
        }
    }

    /// Whether session logging is enabled. Disabling closes the current log
    /// file. Enabling without a folder selected is a no-op for writes.
    var loggingEnabled: Bool {
        get { _loggingEnabled }
        set {
            _loggingEnabled = newValue
            sessionLogger.setEnabled(newValue)
            if newValue {
                // Reseed a session on the active model so the next event opens
                // a fresh file (or no-ops if no model is loaded).
                if let config = _currentModelConfig,
                   let name = _currentModelDisplayName {
                    sessionLogger.startSession(dimension: config.dimension,
                                               modelDisplayName: name)
                }
            }
        }
    }

    /// Set the logs folder from a user-picked URL. Creates a security-scoped
    /// bookmark, hands it to the logger, and persists it in `fullState`.
    func setLogFolder(url: URL) {
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
            _logFolderBookmarkData = bookmark
            _logFolderDisplayPath = url.path
            sessionLogger.setFolderBookmark(bookmark)
            // If a model is loaded, re-arm the session so the next event opens
            // a file in the new folder.
            if _loggingEnabled,
               let config = _currentModelConfig,
               let name = _currentModelDisplayName {
                sessionLogger.startSession(dimension: config.dimension,
                                           modelDisplayName: name)
            }
            NotificationCenter.default.post(name: .IMPSYLogFolderChanged, object: self,
                                            userInfo: ["path": url.path])
        } catch {
            NSLog("[IMPSY] Failed to create log folder bookmark: %@",
                  String(describing: error))
        }
    }

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
    ///
    /// The security scope is only valid for the synchronous span of this
    /// function, so we read the model bytes into memory here and hand them
    /// (not the URL) to the engine. The engine swaps in the new RNN on its
    /// own queue and never touches the user's URL.
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

            let modelData = try Data(contentsOf: url)
            let config = try ModelInspector.inspect(modelData: modelData)
            _currentModelConfig       = config
            _currentModelDisplayName  = url.lastPathComponent
            _modelBookmarkData        = bookmark

            // Mapping count is decoupled from model dim: leave the existing
            // mappings alone. Excess rows beyond model dim are ignored; missing
            // rows behave as if disabled.
            engine.updateMappings(_currentMappings)

            engine.loadModel(modelData: modelData,
                             displayName: url.lastPathComponent,
                             config: config)

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

    static let defaultModelName = "default-dim9"

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
            let modelData = try Data(contentsOf: url)
            let config = try ModelInspector.inspect(modelData: modelData)
            _currentModelConfig      = config
            _currentModelDisplayName = url.lastPathComponent
            // The bundled model is the 9-dimension MDRNN; give it the AiC
            // U6MIDI Pro mapping by default. For any other dimension, keep
            // whatever mappings are already configured (they may be empty;
            // the user can add rows manually).
            let updated = config.dimension == 9
                ? MIDIMappingSet.aicU6MIDIProDefault()
                : _currentMappings
            _currentMappings = updated
            engine.updateMappings(updated)
            engine.loadModel(modelData: modelData,
                             displayName: url.lastPathComponent,
                             config: config)
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
        state[StateKey.inputThru] = engine.inputThru ? Float(1) : Float(0)
        state[StateKey.dedupNoteWindowMs] = _dedupNoteWindowMs
        state[StateKey.dedupCCWindowMs]   = _dedupCCWindowMs

        if let bookmark = _logFolderBookmarkData {
            state[StateKey.logFolderBookmark] = bookmark
        }
        if let path = _logFolderDisplayPath {
            state[StateKey.logFolderName] = path
        }
        state[StateKey.loggingEnabled] = _loggingEnabled ? Float(1) : Float(0)

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
        if let v = state[StateKey.inputThru] as? Float {
            engine.inputThru = v > 0.5
            parameterTree_?[ParameterAddress.inputThru.rawValue]?.value = v
        }
        if let v = state[StateKey.dedupNoteWindowMs] as? Float {
            _dedupNoteWindowMs = v
            engine.dedupNoteWindowMs = v
        }
        if let v = state[StateKey.dedupCCWindowMs] as? Float {
            _dedupCCWindowMs = v
            engine.dedupCCWindowMs = v
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

        // Restore log folder + enabled flag (apply to the logger before the
        // model loads so any session start that fires below picks them up).
        if let bookmark = state[StateKey.logFolderBookmark] as? Data {
            _logFolderBookmarkData = bookmark
            sessionLogger.setFolderBookmark(bookmark)
        }
        _logFolderDisplayPath = state[StateKey.logFolderName] as? String
        if let v = state[StateKey.loggingEnabled] as? Float {
            _loggingEnabled = v > 0.5
            sessionLogger.setEnabled(_loggingEnabled)
        }

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
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                // Read while the scope is held — the engine works from these
                // bytes on its own queue and never re-opens the user's URL.
                let modelData = try Data(contentsOf: url)
                let config = try ModelInspector.inspect(modelData: modelData)
                self?._currentModelConfig = config
                self?.engine.loadModel(modelData: modelData,
                                       displayName: url.lastPathComponent,
                                       config: config)

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
