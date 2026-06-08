import Foundation

// MARK: - UITestEnvKeys
//
// String constants used to pass test-only state from the XCUITest runner to
// the host app via XCUIApplication.launchEnvironment. Kept in sync (by name)
// with HostTestHooks in the host target — duplicated here because the UI test
// bundle does not link the host sources.

enum UITestEnvKeys {
    static let modelB64   = "IMPSY_TEST_MODEL_B64"
    static let configB64  = "IMPSY_TEST_CONFIG_B64"
    static let logFolder  = "IMPSY_TEST_LOG_FOLDER"
    static let injectHz   = "IMPSY_TEST_INJECT_INPUT_HZ"
}
