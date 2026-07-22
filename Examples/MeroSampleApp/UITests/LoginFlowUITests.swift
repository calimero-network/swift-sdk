import XCTest

/// XCUITest — the Swift analog of a Playwright browser test. Launches the app in
/// the simulator with a mocked backend and drives the real UI: type into the
/// login form, tap through to the home screen, run an RPC, and log out.
final class LoginFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest-mock"]
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

    /// Types into a text field. The focusing tap on a SwiftUI field intermittently
    /// fails to give it keyboard focus (a well-known XCUITest + simulator flake) —
    /// and `typeText` then hard-fails with "no keyboard focus", which can't be
    /// caught. So retry the tap until the field actually reports `hasKeyboardFocus`,
    /// then type. Checking focus on *this* field (not just "a keyboard exists")
    /// avoids typing into the wrong field when a keyboard is already up.
    private func type(
        _ field: XCUIElement, _ text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "field not found", file: file, line: line)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        var gotFocus = false
        for _ in 0..<5 {
            // Coordinate tap (see tap(untilExists:)): avoids the flaky AX
            // scroll-to-visible that `field.tap()` triggers on the CI simulator.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let exp = XCTNSPredicateExpectation(predicate: focused, object: field)
            if XCTWaiter().wait(for: [exp], timeout: 2) == .completed {
                gotFocus = true
                break
            }
        }
        XCTAssertTrue(gotFocus, "field never took keyboard focus", file: file, line: line)
        field.typeText(text)
    }

    func testLoginRunRpcAndLogout() throws {
        // Login screen is shown.
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))

        // Fill the form (node URL is prefilled).
        type(app.textFields["usernameField"], "dev")
        type(app.secureTextFields["passwordField"], "dev-password")

        // Log in → home screen appears.
        tap(
            app.buttons["loginButton"], untilExists: app.staticTexts["homeTitle"],
            message: "should navigate to Home after login")
        XCTAssertTrue(app.staticTexts["homeUser"].label.contains("dev"))

        // Run the sample RPC → result appears.
        tap(
            app.buttons["runRpcButton"], untilExists: app.staticTexts["rpcResult"],
            message: "RPC result should appear")

        // Log out → back to the login screen.
        tap(
            app.buttons["logoutButton"], untilExists: app.staticTexts["loginTitle"],
            message: "should return to Login after logout")
    }

    func testValidationErrorOnEmptyCredentials() throws {
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))

        // Tap Log In with empty username/password → inline error, still on login.
        tap(
            app.buttons["loginButton"], untilExists: app.staticTexts["loginError"],
            message: "empty credentials should surface an inline error")
        XCTAssertTrue(app.staticTexts["loginTitle"].exists)
    }
}
