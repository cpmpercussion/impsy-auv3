import XCTest

// MARK: - ScreenshotCaptureTests
//
// Not a behavioural test — a screenshot *generator* for App Store and website
// assets. It is inert unless launched with IMPSY_CAPTURE=1 (XCTSkip otherwise),
// so it never runs during smoke.sh / CI. Driven by scripts/capture-screenshots.sh,
// which mocks the iOS status bar (9:41) and pulls the attachments out of the
// .xcresult.
//
// One run captures all three screens in BOTH light and dark by relaunching the
// host with IMPSY_TEST_APPEARANCE set (IMPSYMainView forces .preferredColorScheme
// from it). On iOS we grab the full device screen (with the mocked status bar);
// on macOS we grab just the app window, which the site frames directly and the
// App Store mockup composites onto a 16:10 canvas.

final class ScreenshotCaptureTests: IMPSYUITestCase {

    func testCaptureScreens() throws {
        guard ProcessInfo.processInfo.environment["IMPSY_CAPTURE"] == "1" else {
            throw XCTSkip("Set IMPSY_CAPTURE=1 to generate screenshots.")
        }

        // dim-9 model → 8 user dimensions (matches the site copy), with the
        // default AiC config so the Mapping screen shows populated CC rows.
        let model = try fixtureBase64(
            name: "musicMDRNN-dim9-layers2-units64-mixtures5-scale10", ext: "tflite")
        let config = try fixtureBase64(name: "AiC-charles-u6midipro", ext: "toml")

        // macOS: force both appearances via the window's NSAppearance (the host
        //   VC reads IMPSY_TEST_APPEARANCE), so one run captures light + dark.
        // iOS: the simulator's system appearance is set externally by the
        //   capture script (`simctl ui appearance`); we capture that single
        //   pass, labelled by IMPSY_SHOT_APPEARANCE, so content AND the mocked
        //   status bar are consistently light or dark.
        #if os(macOS)
        let appearances = ["light", "dark"]
        #else
        let appearances = [ProcessInfo.processInfo.environment["IMPSY_SHOT_APPEARANCE"] ?? "light"]
        #endif

        for appearance in appearances {
            let app = XCUIApplication()
            app.launchEnvironment[UITestEnvKeys.modelB64]  = model
            app.launchEnvironment[UITestEnvKeys.configB64] = config
            #if os(macOS)
            app.launchEnvironment["IMPSY_TEST_APPEARANCE"] = appearance
            #endif
            app.launch()

            // Model loaded + engine generating: with no live input the engine
            // crosses the threshold into RESPONSE and drives the faders.
            waitForModelReady(dimension: 9, in: app)
            waitForResponseState(in: app)

            for screen in [Screen.dashboard, .settings, .mapping] {
                switchToScreen(screen, in: app)
                Thread.sleep(forTimeInterval: 1.5) // let the screen settle / a flash land
                let attachment = XCTAttachment(screenshot: capture(app))
                attachment.name = "impsy-\(appearance)-\(screen.rawValue.lowercased())"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
        }
    }

    private func capture(_ app: XCUIApplication) -> XCUIScreenshot {
        #if os(macOS)
        return app.windows.firstMatch.screenshot()
        #else
        return XCUIScreen.main.screenshot()
        #endif
    }
}
