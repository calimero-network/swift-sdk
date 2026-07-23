import XCTest

/// Full-feature end-to-end test of the app against a LIVE node + registry (the
/// iOS analog of a Playwright e2e). Covers: credential login → explorer method
/// call → chat install → space → channel → send & read a message.
///
/// Requires a real node on http://localhost:4001 (admin dev/dev-password) with
/// registry access. NOT part of the default mock CI — `ui.yml` skips this class
/// and `e2e-ios.sh` runs it with a node booted. Run:
///   ./e2e-ios.sh
final class AppE2ETests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: helpers

    private func type(_ id: String, _ text: String) {
        let field = app.textFields[id].exists ? app.textFields[id] : app.secureTextFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(id) not found")
        for _ in 0..<6 {
            field.tap()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            if XCTWaiter().wait(for: [focused], timeout: 2) == .completed { break }
        }
        field.typeText(text)
    }

    private func tap(_ button: XCUIElement, _ message: String, timeout: TimeInterval = 10) {
        XCTAssertTrue(button.waitForExistence(timeout: timeout), message)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func login() {
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))
        type("usernameField", "dev")
        type("passwordField", "dev-password")
        tap(app.buttons["loginButton"], "login button")
        XCTAssertTrue(app.buttons["openChat"].waitForExistence(timeout: 20), "did not reach explorer")
    }

    // MARK: tests

    /// Explorer: run a live admin method and assert a real response comes back.
    func testExplorerRunsLiveMethod() throws {
        login()
        // Categories are collapsed; search reveals (auto-expands) the method.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field")
        field.tap(); field.typeText("getContexts")
        XCTAssertTrue(app.staticTexts["getContexts"].waitForExistence(timeout: 5), "getContexts row")
        app.staticTexts["getContexts"].firstMatch.tap()
        tap(app.buttons["Run"], "Run button")
        // The response viewer shows the "RESPONSE" label with JSON on success.
        XCTAssertTrue(app.staticTexts["RESPONSE"].waitForExistence(timeout: 15), "no RESPONSE from getContexts")
    }

    /// Chat: install curb, create a space + channel, send and read a message.
    func testChatEndToEnd() throws {
        login()
        app.buttons["openChat"].tap()
        XCTAssertTrue(app.buttons["installChat"].waitForExistence(timeout: 5), "install button")
        app.buttons["installChat"].tap()
        // registry fetch + install can be slow — wait, do NOT tap yet
        XCTAssertTrue(app.buttons["chatAdd"].waitForExistence(timeout: 90), "install did not complete")

        // create space
        app.buttons["chatAdd"].tap()
        XCTAssertTrue(app.buttons["New space"].waitForExistence(timeout: 5), "New space item")
        app.buttons["New space"].tap()
        let spaceField = app.alerts.textFields.firstMatch
        XCTAssertTrue(spaceField.waitForExistence(timeout: 5))
        spaceField.tap(); spaceField.typeText("e2e-space")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["e2e-space"].waitForExistence(timeout: 20), "space not created")
        app.staticTexts["e2e-space"].firstMatch.tap()

        // create channel
        XCTAssertTrue(app.buttons["channelAdd"].waitForExistence(timeout: 10), "channel add menu")
        app.buttons["channelAdd"].tap()
        XCTAssertTrue(app.buttons["New channel"].waitForExistence(timeout: 5), "New channel item")
        app.buttons["New channel"].tap()
        let channelField = app.alerts.textFields.firstMatch
        XCTAssertTrue(channelField.waitForExistence(timeout: 5))
        channelField.tap(); channelField.typeText("general")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["general"].waitForExistence(timeout: 30), "channel not created")

        // invite: generate a code (still on the channels list)
        app.buttons["channelAdd"].tap()
        XCTAssertTrue(app.buttons["Invite people"].waitForExistence(timeout: 5), "Invite item")
        app.buttons["Invite people"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 20), "invite code not generated")
        app.buttons["Done"].tap()

        // send + read a message
        app.staticTexts["general"].firstMatch.tap()
        let composer = app.textFields["messageField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("e2e hello")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["e2e hello"].waitForExistence(timeout: 20), "message not shown")
    }
}
