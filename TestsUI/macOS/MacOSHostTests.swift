import XCTest

// MARK: - MacOSHostTests
//
// macOS-only smoke. The host window has a single bottom-strip label showing
// the CoreMIDI virtual-port bridge state. On success it reads:
//     MIDI Bridge: ✓ virtual ports active (IMPSY In · IMPSY Out)

final class MacOSHostTests: IMPSYUITestCase {

    func testBridgeStatusReportsActive() {
        let app = launchHost()
        let label = app.staticTexts["host.bridgeStatusLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 10),
                      "host.bridgeStatusLabel not found.")
        let predicate = NSPredicate(format: "value CONTAINS '✓' OR label CONTAINS '✓'")
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: label)
        XCTAssertEqual(
            XCTWaiter().wait(for: [exp], timeout: 10),
            .completed,
            "Expected bridge status to report active, got '\(label.label)'."
        )
    }
}
