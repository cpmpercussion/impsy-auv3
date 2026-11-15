import Foundation

// MARK: - HostSession
//
// Saves and restores the standalone host's session — model, MIDI mappings,
// parameters, note dedup window, logging setup — across launches. A plugin
// host (AUM, Logic, …) does this for the AUv3 by storing `fullState` in its
// project; the standalone apps have no project, so they keep the same
// dictionary in UserDefaults.
//
// The session is written whenever it changes (checked every couple of
// seconds) as well as on quit / backgrounding, so a crash or force-quit
// mid-performance loses at most the last couple of seconds of edits.
//
// Main-thread only.

final class HostSession {

    /// Launch-environment override, for UI tests. `off` disables the session
    /// entirely (the default for UI tests, which expect a factory-fresh app);
    /// any other value namespaces the saved session so tests never touch the
    /// user's real one.
    static let testSessionKey = "IMPSY_TEST_SESSION"
    /// Launch-environment flag, for UI tests: discard any saved session at
    /// startup, so a test's first launch starts clean.
    static let testSessionResetKey = "IMPSY_TEST_SESSION_RESET"

    private static let autosaveInterval: TimeInterval = 2

    private let audioUnit: IMPSYAudioUnit
    private let defaults: UserDefaults
    private let stateKey: String
    private let restoreAttemptsKey: String
    private var restoreUnconfirmed = false
    private var lastSaved: NSDictionary?
    private var autosaveTimer: Timer?

    /// Nil when the session is disabled by the test environment.
    init?(audioUnit: IMPSYAudioUnit, defaults: UserDefaults = .standard) {
        let override = ProcessInfo.processInfo.environment[Self.testSessionKey] ?? ""
        guard override != "off" else { return nil }
        let suffix = override.isEmpty ? "" : ".test.\(override)"

        self.audioUnit = audioUnit
        self.defaults = defaults
        stateKey = "impsy.host.session\(suffix)"
        restoreAttemptsKey = "impsy.host.session.restoreAttempts\(suffix)"

        // Keep the loaded model's bytes inside the app's own container so the
        // session can be restored without the original file (see
        // `IMPSYAudioUnit.modelCacheURL`).
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true) {
            audioUnit.modelCacheURL = support
                .appendingPathComponent("IMPSY", isDirectory: true)
                .appendingPathComponent("session-model\(suffix).tflite")
        }

        if ProcessInfo.processInfo.environment[Self.testSessionResetKey] != nil {
            defaults.removeObject(forKey: stateKey)
            defaults.removeObject(forKey: restoreAttemptsKey)
            if let cache = audioUnit.modelCacheURL {
                try? FileManager.default.removeItem(at: cache)
            }
        }
    }

    deinit {
        autosaveTimer?.invalidate()
    }

    /// Apply the saved session, if there is one. Call once, before the UI is
    /// attached, so the view model picks up the restored state.
    func restore() {
        guard let data = defaults.data(forKey: stateKey) else { return }

        // A session that crashes the app as it loads would otherwise do so on
        // every launch. Each restore is counted until the first save after it
        // (a couple of seconds in, or a clean quit) confirms the app survived;
        // after two unconfirmed attempts in a row, give up on the session.
        // Two, not one, so a single force-quit straight after launch doesn't
        // throw the session away.
        let attempts = defaults.integer(forKey: restoreAttemptsKey)
        if attempts >= 2 {
            NSLog("[IMPSY] HostSession: session failed to restore twice; starting fresh")
            defaults.removeObject(forKey: restoreAttemptsKey)
            defaults.removeObject(forKey: stateKey)
            return
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let state = plist as? [String: Any] else {
            NSLog("[IMPSY] HostSession: saved session is unreadable; starting fresh")
            defaults.removeObject(forKey: stateKey)
            return
        }

        defaults.set(attempts + 1, forKey: restoreAttemptsKey)
        restoreUnconfirmed = true
        audioUnit.fullState = state
        NSLog("[IMPSY] HostSession: restored saved session")
    }

    /// Begin saving the session whenever it changes.
    func startAutosave() {
        autosaveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            self?.save()
        }
        timer.tolerance = Self.autosaveInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    /// Write the session now if it differs from what was last written.
    func save() {
        if restoreUnconfirmed {
            restoreUnconfirmed = false
            defaults.removeObject(forKey: restoreAttemptsKey)
        }
        guard let state = audioUnit.fullState else { return }
        if let lastSaved, lastSaved.isEqual(to: state) { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: state,
                                                          format: .binary, options: 0)
            defaults.set(data, forKey: stateKey)
            lastSaved = NSDictionary(dictionary: state)
        } catch {
            NSLog("[IMPSY] HostSession: could not save session: %@", String(describing: error))
        }
    }
}
