import AudioToolbox
import Foundation

// MARK: - IMPSYAudioUnit TOML Import/Export
//
// Round-trip with IMPSY's TOML config format (see `IMPSYConfig.swift` and
// issue #3). Import applies parameter values, MIDI thru, and input/output
// mappings; the model file path is read but not auto-resolved — model
// loading stays under the existing security-scoped bookmark workflow.
//
// Threading: TOML import/export is a synchronous main-thread operation. We
// touch the parameter tree (thread-safe) and `currentMappings` (which is
// already updated via `engine.updateMappings` whenever it's written, and
// that dispatches to the inference queue).

extension IMPSYAudioUnit {

    // MARK: - Notifications

    /// Posted on `IMPSYAudioUnit` after a successful TOML import so the
    /// view model can re-sync its `@Published` mirror of params + mappings.
    /// Userinfo: `["filename": String]` — the source TOML's lastPathComponent.
    static let configImportedNotification = Notification.Name("IMPSYConfigImported")

    // MARK: - Import

    func loadConfig(url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let toml = String(data: data, encoding: .utf8) else {
            throw IMPSYConfig.ParseError.malformed("file is not valid UTF-8")
        }
        let config = try IMPSYConfig.parse(toml)
        apply(config)

        NotificationCenter.default.post(
            name: IMPSYAudioUnit.configImportedNotification,
            object: self,
            userInfo: ["filename": url.lastPathComponent]
        )
    }

    /// Apply a parsed config to live AU state — exposed separately so tests
    /// can exercise it without going through a file URL.
    func apply(_ config: IMPSYConfig) {
        // Parameter tree drives the engine and any UI observers.
        if let tree = parameterTree_ {
            tree.parameter(withAddress: ParameterAddress.threshold.rawValue)?.value = config.threshold
            tree.parameter(withAddress: ParameterAddress.sigmaTemp.rawValue)?.value = config.sigmaTemp
            tree.parameter(withAddress: ParameterAddress.piTemp.rawValue)?.value    = config.piTemp
            tree.parameter(withAddress: ParameterAddress.timescale.rawValue)?.value = config.timescale
            tree.parameter(withAddress: ParameterAddress.inputThru.rawValue)?.value = config.inputThru ? 1 : 0
        }

        // Replace the mappings wholesale. `currentMappings`'s setter syncs to
        // the engine on its own queue.
        var newMappings = MIDIMappingSet(
            inputMappings: config.inputMappings,
            outputMappings: config.outputMappings
        )
        // If the model is loaded, resize to its dimension so we never produce
        // more or fewer mapping rows than the engine expects.
        if let dim = currentModelConfig?.dimension {
            newMappings.resize(toModelDimension: dim)
        }
        currentMappings = newMappings
    }

    // MARK: - Export

    /// Build a TOML string snapshot of current AU state. The exported file
    /// always names a single synthetic device (`"AUv3"`) for the input/output
    /// mapping arrays — see #3 for the IMPSY-vs-AUv3 schema mapping.
    func exportConfig() throws -> String {
        var config = IMPSYConfig()
        if let tree = parameterTree_ {
            config.threshold = tree.parameter(withAddress: ParameterAddress.threshold.rawValue)?.value ?? config.threshold
            config.sigmaTemp = tree.parameter(withAddress: ParameterAddress.sigmaTemp.rawValue)?.value ?? config.sigmaTemp
            config.piTemp    = tree.parameter(withAddress: ParameterAddress.piTemp.rawValue)?.value    ?? config.piTemp
            config.timescale = tree.parameter(withAddress: ParameterAddress.timescale.rawValue)?.value ?? config.timescale
            let thru = tree.parameter(withAddress: ParameterAddress.inputThru.rawValue)?.value ?? ParameterDefaults.inputThru
            config.inputThru = thru > 0.5
        }
        config.modelFile      = _currentModelDisplayName
        config.modelDimension = _currentModelConfig?.dimension
        config.inputMappings  = _currentMappings.inputMappings
        config.outputMappings = _currentMappings.outputMappings
        return try config.serialize()
    }

    func writeConfig(to url: URL) throws {
        let toml = try exportConfig()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try toml.write(to: url, atomically: true, encoding: .utf8)
    }
}
