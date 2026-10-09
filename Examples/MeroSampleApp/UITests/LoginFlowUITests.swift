import XCTest

/// XCUITest — the Swift analog of a Playwright browser test. Launches the app in
/// the simulator with a mocked Cloud + relay and drives the real UI: Cloud
/// sign-in, the home screen, a read through the relay, and sign out.
///
/// The wallet's web sheet is replaced in `-uitest-mock` by an in-app wallet
/// that certifies the device key the app names, so the app's own credential
/// verification still runs. `-uitest-enrol-callback <url>` injects a canned
/// callback instead (used here for a declined sign-in).
final class LoginFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest-mock"]
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments += extra
        app.launch()
    }

    /// Taps `button`, then waits for `expected` to appear — retrying the tap if it
    /// doesn't. SwiftUI intermittently drops a tap before its gesture recognizers
    /// are attached (most often the first interaction after launch, but it can hit
    /// any button), so a single tap is not reliable. Re-checking `expected` before
    /// each re-tap keeps it safe once the transition has already happened.
    private func tap(
        _ button: XCUIElement,
        untilExists expected: XCUIElement,
        timeout: TimeInterval = 5,
        retries: Int = 3,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "button not found. \(message)", file: file, line: line)
        for _ in 0...retries {
            if expected.exists { return }
            // Tap via a coordinate rather than `button.tap()`. `.tap()` first runs an
            // AX "scroll to visible" action, which flakily throws kAXErrorCannotComplete
            // on the CI simulator (iPhone 16 Pro) even for on-screen buttons. A
            // coordinate tap hits the element's centre directly and skips that step.
            if button.exists {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if expected.waitForExistence(timeout: timeout) { return }
        }
        XCTFail("expected element never appeared after tapping. \(message)", file: file, line: line)
    }

    func testCloudSignInReadAndSignOut() throws {
        launch()
        // The Cloud sign-in screen: one button, no node URL, no password.
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["nodeURLField"].exists)
        XCTAssertFalse(app.secureTextFields["passwordField"].exists)

        // Continue with Calimero → the (mock) wallet certifies this device → home.
        tap(
            app.buttons["cloudSignInButton"], untilExists: app.staticTexts["homeTitle"],
            message: "should reach Home after Cloud sign-in")
        let relay = app.descendants(matching: .any)["homeNodeURL"]
        XCTAssertTrue(relay.waitForExistence(timeout: 5))
        XCTAssertTrue(relay.label.contains("relay.mock"), relay.label)

        // A read through the relay → result appears.
        tap(
            app.buttons["runRpcButton"], untilExists: app.staticTexts["rpcResult"],
            message: "relay read result should appear")

        // Sign out → back to the sign-in screen.
        tap(
            app.buttons["logoutButton"], untilExists: app.staticTexts["loginTitle"],
            message: "should return to sign-in after sign out")
    }

    func testDeclinedEnrolmentShowsAnInlineError() throws {
        launch(["-uitest-enrol-callback", "mero-sample://enrol#error=cancelled"])
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))

        tap(
            app.buttons["cloudSignInButton"], untilExists: app.descendants(matching: .any)["loginError"],
            message: "a declined enrolment should surface an inline error")
        XCTAssertTrue(app.staticTexts["loginTitle"].exists)
        XCTAssertFalse(app.staticTexts["homeTitle"].exists)
    }
}
