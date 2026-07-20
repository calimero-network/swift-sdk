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

    func testLoginRunRpcAndLogout() throws {
        // Login screen is shown.
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))

        // Fill the form (node URL is prefilled).
        let username = app.textFields["usernameField"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("dev")

        let password = app.secureTextFields["passwordField"]
        password.tap()
        password.typeText("dev-password")

        // Log in → home screen appears.
        app.buttons["loginButton"].tap()
        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 5), "should navigate to Home after login")
        XCTAssertTrue(app.staticTexts["homeUser"].label.contains("dev"))

        // Run the sample RPC → result appears.
        app.buttons["runRpcButton"].tap()
        XCTAssertTrue(app.staticTexts["rpcResult"].waitForExistence(timeout: 5))

        // Log out → back to the login screen.
        app.buttons["logoutButton"].tap()
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5), "should return to Login after logout")
    }

    func testValidationErrorOnEmptyCredentials() throws {
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))

        // Tap Log In with empty username/password → inline error, still on login.
        app.buttons["loginButton"].tap()
        XCTAssertTrue(app.staticTexts["loginError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["loginTitle"].exists)
    }
}
