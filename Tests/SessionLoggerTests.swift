import XCTest
// Common sources are compiled directly into this test target (see project.yml)

final class SessionLoggerTests: XCTestCase {

    // MARK: - Format helpers

    func testCurrentTimestampShape() {
        // 2024-01-02T03:04:05.000000 → 26 chars: ten date + 'T' + 8 time + dot + 6 micros
        let date = Date(timeIntervalSince1970: 1_704_164_645.123456)
        let ts = SessionLogger.currentTimestamp(date: date)
        let regex = try! NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}$"#)
        XCTAssertNotNil(regex.firstMatch(in: ts, range: NSRange(ts.startIndex..., in: ts)),
                        "timestamp \(ts) does not match the IMPSY Python isoformat shape")
        XCTAssertTrue(ts.hasSuffix(".123456"),
                      "microseconds lost: got \(ts)")
    }

    func testMakeFileNameMatchesPythonShape() {
        let date = Date(timeIntervalSince1970: 1_724_927_977) // 2024-08-29T10:39:37 UTC
        let name = SessionLogger.makeFileName(dimension: 9, date: date)
        // The actual hour digits depend on the test host's locale, but the
        // shape must be YYYY-MM-DDTHH-MM-SS-9d-mdrnn.log.
        let regex = try! NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-9d-mdrnn\.log$"#)
        XCTAssertNotNil(regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                        "filename \(name) does not match IMPSY Python pattern")
    }

    func testFormatValueRoundTripsThroughPythonFloat() {
        // Swift's default Float.description is the shortest round-trip — the
        // same approach Python uses for repr(float). For our purposes the
        // important property is that the printed string parses back to the
        // same Float.
        for v: Float in [0.0, 1.0, 0.5, 0.123456, 0.875111, 0.007874015] {
            let s = SessionLogger.formatValue(v)
            let parsed = Float(s)
            XCTAssertEqual(parsed, v, "round-trip failed for \(v) → \(s)")
        }
        XCTAssertEqual(SessionLogger.formatValue(0.0), "0.0",
                       "matched Python's `str(0.0)` to give a parseable zero")
    }

    // MARK: - End-to-end file writing

    func testEnabledLoggerWritesInterfaceAndRNNLines() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let logger = SessionLogger()
        logger.setEnabled(true)
        // Real flows go through a security-scoped bookmark; the temp folder
        // bypasses that, so just feed it directly using the same internal API.
        let bookmark = try folder.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        logger.setFolderBookmark(bookmark)
        logger.startSession(dimension: 4, modelDisplayName: "test-model.tflite")

        logger.logInterface(values: [0.1, 0.2, 0.3])
        logger.logRNN(values: [0.5, 0.6, 0.7])
        logger.endSession()
        flushLogger(logger)

        let logURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: folder,
                                                       includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "log" },
            "no .log file written"
        )
        XCTAssertTrue(logURL.lastPathComponent.hasSuffix("-4d-mdrnn.log"),
                      "filename does not match expected suffix: \(logURL.lastPathComponent)")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        let dataLines = text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }

        XCTAssertEqual(dataLines.count, 2, "expected 1 interface + 1 rnn line")
        let interfaceLine = String(try XCTUnwrap(dataLines.first { $0.contains(",interface,") }))
        let rnnLine       = String(try XCTUnwrap(dataLines.first { $0.contains(",rnn,") }))

        // Match Python's `log_interaction`: `<iso>,source,v1,v2,...`.
        XCTAssertTrue(interfaceLine.hasSuffix(",interface,0.1,0.2,0.3"),
                      "interface line malformed: \(interfaceLine)")
        XCTAssertTrue(rnnLine.hasSuffix(",rnn,0.5,0.6,0.7"),
                      "rnn line malformed: \(rnnLine)")
    }

    func testDisabledLoggerWritesNothing() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let logger = SessionLogger()
        let bookmark = try folder.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        logger.setFolderBookmark(bookmark)
        logger.startSession(dimension: 3, modelDisplayName: "x")
        // setEnabled(false) is the default; assert nothing is written.
        logger.logInterface(values: [0.1, 0.2])
        flushLogger(logger)

        let files = try FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
        XCTAssertEqual(files.count, 0, "logger wrote a file while disabled: \(files)")
    }

    func testEndSessionThenStartSessionRollsToNewFile() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let logger = SessionLogger()
        logger.setEnabled(true)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        logger.setFolderBookmark(bookmark)

        logger.startSession(dimension: 3, modelDisplayName: "a.tflite")
        logger.logInterface(values: [0.1, 0.2])
        flushLogger(logger)

        // Force a different file name by waiting a second — file naming is
        // second-resolution. 1.1s gives ample headroom across timezones.
        Thread.sleep(forTimeInterval: 1.1)

        logger.startSession(dimension: 3, modelDisplayName: "b.tflite")
        logger.logInterface(values: [0.5, 0.6])
        flushLogger(logger)

        let files = try FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
        XCTAssertEqual(files.count, 2,
                       "expected exactly two log files after session roll: \(files)")
    }

    // MARK: - Helpers

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("impsy-logger-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// SessionLogger marshals onto an internal queue; this round-trips a
    /// sync block on the same `DispatchQueue.global()` after our test calls
    /// to give those internal writes a chance to land before assertions.
    private func flushLogger(_ logger: SessionLogger,
                             waitFor seconds: TimeInterval = 0.5) {
        let exp = expectation(description: "logger settled")
        // The logger has no public sync hook, so we rely on the fact that a
        // followup `endSession()` (a no-op once already ended) is also async,
        // and after a brief settle the writer queue will have drained.
        logger.endSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 0.5)
    }
}
