import Foundation

// MARK: - SessionLogger
//
// Records interaction events to a `.log` file in the format used by IMPSY
// Python (../impsy/impsy/interaction.py). Each line is:
//
//   YYYY-MM-DDTHH:mm:ss.ffffff,{interface|rnn},v1,v2,...,vN
//
// where v1…vN are the *modeled* dimensions in [0,1] — no dt. dt is reconstructed
// from timestamp diffs by the dataset loader (../impsy/impsy/dataset.py).
//
// File naming matches Python: `<iso-with-dashes>-{dimension}d-mdrnn.log`, where
// `dimension` is the model's full dimension (includes dt as dim 0).
//
// Storage location is a user-picked folder; we resolve a security-scoped
// bookmark and hold the scope for the lifetime of the writing session.
//
// All mutable state is touched only on `queue`. Public API dispatches onto it.

final class SessionLogger: @unchecked Sendable {

    // MARK: Public configuration

    /// Whether logging is enabled. Combined with a resolved folder URL and an
    /// active session this gates file writes. Safe to call from any thread.
    func setEnabled(_ enabled: Bool) {
        queue.async { self._setEnabled(enabled) }
    }

    /// Set the user-selected logs folder via a security-scoped bookmark. Pass
    /// `nil` to clear. Replaces any previous folder; closes the current file
    /// if one is open.
    func setFolderBookmark(_ bookmark: Data?) {
        queue.async { self._setFolderBookmark(bookmark) }
    }

    /// Called by the engine when a new model becomes active. Decides the
    /// filename based on `dimension` and "now", but defers opening the file
    /// until the first event is logged (matches Python's `delay_file_open`).
    func startSession(dimension: Int, modelDisplayName: String) {
        queue.async { self._startSession(dimension: dimension, modelDisplayName: modelDisplayName) }
    }

    /// Close the current file (if any) and clear session state.
    func endSession() {
        queue.async { self._endSession() }
    }

    // MARK: Public logging API (called from InteractionEngine's inference queue)

    /// Record a user-input event. `values` is the current input vector in
    /// modeled-dim order — index 0 = dim 1, length = `dimension - 1`.
    func logInterface(values: [Float]) {
        let captured = values
        queue.async { self._writeLine(source: "interface", values: captured) }
    }

    /// Record an RNN-generated event. `values` is the post-clamp output for
    /// modeled dimensions only (no dt).
    func logRNN(values: [Float]) {
        let captured = values
        queue.async { self._writeLine(source: "rnn", values: captured) }
    }

    // MARK: - Implementation

    private let queue = DispatchQueue(label: "impsy.logger", qos: .utility)

    // Configuration & state (only touched on `queue`)
    private var enabled: Bool = false
    private var folderURL: URL?
    private var isAccessingFolder: Bool = false
    private var pendingFileName: String?         // assigned at startSession; cleared on file open
    private var currentFileURL: URL?
    private var handle: FileHandle?
    private var sessionDimension: Int = 0
    private var sessionModelName: String = ""

    deinit {
        // Best-effort cleanup off the queue — deinit is synchronous and the
        // queue is about to be torn down. Same operations as _endSession().
        if let h = handle { try? h.close() }
        if isAccessingFolder, let u = folderURL { u.stopAccessingSecurityScopedResource() }
    }

    // MARK: Configuration

    private func _setEnabled(_ newValue: Bool) {
        guard enabled != newValue else { return }
        enabled = newValue
        if !enabled {
            _closeCurrentFile()
        }
    }

    private func _setFolderBookmark(_ bookmark: Data?) {
        // Close any open file and drop the current scope before switching.
        _closeCurrentFile()
        if isAccessingFolder, let u = folderURL {
            u.stopAccessingSecurityScopedResource()
            isAccessingFolder = false
        }
        folderURL = nil

        guard let bookmark else { return }

        do {
            var isStale = false
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            #else
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            #endif
            let accessing = url.startAccessingSecurityScopedResource()
            folderURL = url
            isAccessingFolder = accessing
            if isStale {
                NSLog("[IMPSY] SessionLogger: bookmark stale; logs folder may need re-picking")
            }
        } catch {
            NSLog("[IMPSY] SessionLogger: failed to resolve logs bookmark: %@",
                  String(describing: error))
        }
    }

    private func _startSession(dimension: Int, modelDisplayName: String) {
        _closeCurrentFile()
        sessionDimension = dimension
        sessionModelName = modelDisplayName
        pendingFileName = Self.makeFileName(dimension: dimension, date: Date())
    }

    private func _endSession() {
        _closeCurrentFile()
        pendingFileName = nil
        sessionDimension = 0
        sessionModelName = ""
    }

    // MARK: Writing

    private func _writeLine(source: String, values: [Float]) {
        guard enabled else { return }
        guard let folderURL else { return }
        guard sessionDimension > 0 else { return }

        if handle == nil {
            _openFile(in: folderURL)
        }
        guard let handle else { return }

        let timestamp = Self.currentTimestamp()
        let valueString = values.map(Self.formatValue).joined(separator: ",")
        let line = "\(timestamp),\(source),\(valueString)\n"
        if let data = line.data(using: .utf8) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                NSLog("[IMPSY] SessionLogger: write failed: %@", String(describing: error))
                _closeCurrentFile()
            }
        }
    }

    private func _openFile(in folder: URL) {
        guard let name = pendingFileName else { return }
        let url = folder.appendingPathComponent(name)

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            // Header (commented; the Python dataset loader silently skips
            // unparseable rows — verified in ../impsy/impsy/dataset.py).
            let header = Self.headerLines(modelName: sessionModelName,
                                          dimension: sessionDimension)
            if let data = header.data(using: .utf8) {
                try h.write(contentsOf: data)
            }
            handle = h
            currentFileURL = url
            pendingFileName = nil
            NSLog("[IMPSY] SessionLogger: opened %@", name)
        } catch {
            NSLog("[IMPSY] SessionLogger: open failed for %@: %@",
                  url.path, String(describing: error))
        }
    }

    private func _closeCurrentFile() {
        if let h = handle {
            try? h.close()
        }
        handle = nil
        currentFileURL = nil
    }

    // MARK: - Formatting

    /// `YYYY-MM-DDTHH:mm:ss.ffffff` in the device's local time, matching
    /// Python's `datetime.now().isoformat()`. Microsecond precision via the
    /// fractional component of `Date.timeIntervalSince1970`.
    static func currentTimestamp(date: Date = Date()) -> String {
        let secondsString = timestampSecondsFormatter.string(from: date)
        let interval = date.timeIntervalSince1970
        let microseconds = Int(((interval - floor(interval)) * 1_000_000).rounded())
        return String(format: "%@.%06d", secondsString, max(0, min(microseconds, 999_999)))
    }

    static func makeFileName(dimension: Int, date: Date) -> String {
        let stem = fileNameStemFormatter.string(from: date)
        return "\(stem)-\(dimension)d-mdrnn.log"
    }

    static func formatValue(_ v: Float) -> String {
        // Swift's default Float→String is the shortest round-trip
        // representation — same idea as Python's `repr(float)` — so values
        // come out as e.g. "0.0", "0.5039370".
        return String(v)
    }

    private static func headerLines(modelName: String, dimension: Int) -> String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let created = currentTimestamp()
        return """
        # IMPSY AUv3 v\(version) log
        # model=\(modelName)
        # dimension=\(dimension)
        # created=\(created)

        """
    }

    private static let timestampSecondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let fileNameStemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()
}
