import Foundation

// MARK: - HostTestHooks
//
// Test-only entry points driven by launch-environment variables. Both host
// apps call `apply(to:)` after the AU view controller is in place; when an
// env var is absent each hook is a silent no-op, so production launches are
// unchanged.
//
// These hooks exist to let XCUITest drive flows that would otherwise hit
// out-of-process system pickers (UIDocumentPicker, NSOpenPanel, NSSavePanel),
// which are historically flaky to automate. They live in the *host*, not the
// AU extension, so they never ship inside the AUv3 plugin that a DAW loads —
// only the dev/TestFlight host app sees them.

enum HostTestHooks {

    // MARK: - Env keys (also referenced by TestsUI helpers)

    static let modelB64Key   = "IMPSY_TEST_MODEL_B64"
    // NOTE: there is deliberately no file-path variant of the model hook.
    // The sandboxed macOS host cannot read files written by the test runner
    // (its temp dir lives in a different sandbox container), so a path-based
    // hand-off silently fails. Base64 works because *this process* writes
    // the bytes into its own container temp before loading. Keep fixtures
    // small enough for the launch env-var limit (~1 MB total).
    static let configB64Key  = "IMPSY_TEST_CONFIG_B64"
    static let logFolderKey  = "IMPSY_TEST_LOG_FOLDER"
    static let injectHzKey   = "IMPSY_TEST_INJECT_INPUT_HZ"

    // MARK: - Internal state

    private static var injectionTimer: DispatchSourceTimer?
    private static var injectionPhase: Int = 0

    // MARK: - Entry point

    static func apply(to au: IMPSYAudioUnit) {
        let env = ProcessInfo.processInfo.environment
        applyModelHook(au: au, env: env)
        applyConfigHook(au: au, env: env)
        applyLogFolderHook(au: au, env: env)
        applyInputInjectionHook(au: au, env: env)
    }

    // MARK: - Model

    private static func applyModelHook(au: IMPSYAudioUnit, env: [String: String]) {
        guard let b64 = env[modelB64Key], !b64.isEmpty else { return }
        guard let data = Data(base64Encoded: b64) else {
            NSLog("[IMPSY] HostTestHooks: %@ is not valid base64", modelB64Key)
            return
        }
        // Realistic-looking filename: it surfaces verbatim as the model name in
        // the UI (and in App Store screenshots). Tests assert on dimension, not
        // this name.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicMDRNN.tflite")
        do {
            try data.write(to: url)
            au.loadModel(url: url)
            NSLog("[IMPSY] HostTestHooks: queued model load from %@", modelB64Key)
        } catch {
            NSLog("[IMPSY] HostTestHooks: model write failed: %@",
                  String(describing: error))
        }
    }

    // MARK: - Config (TOML)

    private static func applyConfigHook(au: IMPSYAudioUnit, env: [String: String]) {
        guard let b64 = env[configB64Key], !b64.isEmpty else { return }
        guard let data = Data(base64Encoded: b64) else {
            NSLog("[IMPSY] HostTestHooks: %@ is not valid base64", configB64Key)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-test-config.toml")
        do {
            try data.write(to: url)
        } catch {
            NSLog("[IMPSY] HostTestHooks: config write failed: %@",
                  String(describing: error))
            return
        }
        // Defer until the bundled (or env-injected) model has had a chance
        // to load so mappings resize to the model's dimension.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            do {
                try au.loadConfig(url: url)
                NSLog("[IMPSY] HostTestHooks: applied config from %@", configB64Key)
            } catch {
                NSLog("[IMPSY] HostTestHooks: loadConfig failed: %@",
                      String(describing: error))
            }
        }
    }

    // MARK: - Log folder

    private static func applyLogFolderHook(au: IMPSYAudioUnit, env: [String: String]) {
        guard let path = env[logFolderKey], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                  withIntermediateDirectories: true)
        au.setLogFolder(url: url)
        au.loggingEnabled = true
        NSLog("[IMPSY] HostTestHooks: enabled logging into %@", path)
    }

    // MARK: - Input injection
    //
    // Periodically enqueue a MIDI event for each configured input dimension so
    // the engine has something to log / react to without a real controller.
    // Phase counter drives both the dimension index and the per-step value,
    // which keeps the stream deterministic-by-step.

    private static func applyInputInjectionHook(au: IMPSYAudioUnit, env: [String: String]) {
        guard let hzStr = env[injectHzKey], !hzStr.isEmpty,
              let hz = Double(hzStr), hz > 0 else { return }
        let interval = 1.0 / hz
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: interval)
        timer.setEventHandler {
            let mappings = au.currentMappings.inputMappings
            guard !mappings.isEmpty else { return }
            let i = injectionPhase % mappings.count
            injectionPhase += 1
            let mapping = mappings[i]
            let v = Float((injectionPhase * 17) % 128) / 127.0
            let event = MIDIMapper.encode(value: v, using: mapping)
            au.engine.inputBuffer.enqueue(RawMIDIPacket(
                event.statusByte, event.data1, event.data2,
                length: event.byteCount
            ))
        }
        timer.resume()
        injectionTimer = timer
        NSLog("[IMPSY] HostTestHooks: input injection started at %.2f Hz", hz)
    }
}
