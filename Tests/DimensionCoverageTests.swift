import XCTest
// Common sources are compiled directly into this test target (see project.yml)

/// End-to-end coverage across a range of model dimensions (issue #10).
///
/// Loads every `.tflite` under `test-models/` at the repo root, inspects it,
/// runs a few inference steps through `TFLiteRNN`, and checks that the output
/// vector has the right length and contains finite values. Skips cleanly when
/// the directory is missing (it is not committed — see CLAUDE.md / issue #10).
final class DimensionCoverageTests: XCTestCase {

    private static let testModelsDir: URL = {
        // #filePath = .../impsy-auv3/Tests/DimensionCoverageTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Tests/
            .deletingLastPathComponent()        // repo root
            .appendingPathComponent("test-models")
    }()

    private func modelURLs() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.testModelsDir.path) else {
            throw XCTSkip("test-models/ not present at \(Self.testModelsDir.path)")
        }
        let all = try fm.contentsOfDirectory(at: Self.testModelsDir,
                                             includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "tflite" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Per-model status row used by the end-to-end sweep.
    private struct ModelResult {
        let name: String
        let status: String   // "OK" or short failure reason
    }

    /// Inspect + generate against every test-models/*.tflite, never failing on
    /// the first error — we want a full matrix of which dims work and which
    /// don't. Test fails at the end only if any model failed.
    func testEndToEndAcrossAllTestModels() throws {
        let urls = try modelURLs()
        XCTAssertFalse(urls.isEmpty, "test-models/ contained no .tflite files")

        var results: [ModelResult] = []
        for url in urls {
            let name = url.lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let config = try ModelInspector.inspect(modelData: data)
                let rnn = try TFLiteRNN(modelData: data, config: config)
                var seed = InteractionEngine.randomInitialSample(dimension: config.dimension)
                for _ in 0..<5 {
                    let out = try rnn.generate(input: seed, piTemp: 1.0, sigmaTemp: 0.01)
                    guard out.count == config.dimension else {
                        throw NSError(domain: "IMPSYTest", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey:
                                                  "output length \(out.count) ≠ dim \(config.dimension)"])
                    }
                    if let bad = out.firstIndex(where: { !$0.isFinite }) {
                        throw NSError(domain: "IMPSYTest", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey:
                                                  "non-finite output at idx \(bad)"])
                    }
                    seed = out
                }
                results.append(.init(name: name,
                                     status: "OK dim=\(config.dimension) layers=\(config.numLayers) units=\(config.hiddenUnits)"))
            } catch {
                results.append(.init(name: name, status: "FAIL: \(error.localizedDescription)"))
            }
        }

        // Print a tidy summary so we can read the matrix from the test log.
        NSLog("[IMPSY test] ──────────── dimension coverage summary ────────────")
        for r in results { NSLog("[IMPSY test] %@ → %@", r.name, r.status) }
        NSLog("[IMPSY test] ─────────────────────────────────────────────────────")

        let failed = results.filter { $0.status.hasPrefix("FAIL") }
        if !failed.isEmpty {
            XCTFail("\(failed.count)/\(results.count) models failed: " +
                    failed.map { $0.name }.joined(separator: ", "))
        }
    }
}
