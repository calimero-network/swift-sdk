import UIKit
import XCTest

/// Two-user, two-node, two-simulator chat e2e — driven by chat-multi-e2e.sh.
///
/// The harness boots two P2P-connected nodes and two simulators, then runs these
/// roles in order, handing the invite between simulators via the pasteboard:
///   1. sim A / node A:  `testHostCreateInviteAndPost`  → creates space+channel,
///      copies an invite to the pasteboard, posts a message.
///   2. (harness copies the invite from sim A's pasteboard to sim B's)
///   3. sim B / node B:  `testGuestJoinAndReply` → reads the invite from the
///      pasteboard, auto-joins (E2E_JOIN hook), sees the host's message, replies.
///   4. sim A / node A:  `testHostSeesReply` → sees the guest's reply.
///
/// Requires two live nodes + registry; excluded from the mock CI (ui.yml).
final class ChatMultiUserTests: XCTestCase {
    private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
        let f = app.textFields[id].exists ? app.textFields[id] : app.secureTextFields[id]
        XCTAssertTrue(f.waitForExistence(timeout: 5), "\(id) missing")
        for _ in 0..<6 {
            f.tap()
            let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: f)
            if XCTWaiter().wait(for: [e], timeout: 2) == .completed { break }
        }
        f.typeText(text)
    }

    private func login(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["loginTitle"].waitForExistence(timeout: 5))
        type(app, "usernameField", "dev")
        type(app, "passwordField", "dev-password")
        app.buttons["loginButton"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Open Chat"].waitForExistence(timeout: 20), "no explorer")
    }

    private func openChannel(_ app: XCUIApplication, space: String, channel: String, timeout: TimeInterval) {
        XCTAssertTrue(app.staticTexts[space].waitForExistence(timeout: timeout), "space \(space) not visible")
        app.staticTexts[space].tap()
        XCTAssertTrue(app.staticTexts[channel].waitForExistence(timeout: timeout), "channel \(channel) not visible")
        app.staticTexts[channel].tap()
        XCTAssertTrue(app.textFields["messageField"].waitForExistence(timeout: 10), "composer missing")
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.textFields["messageField"]
        composer.tap(); composer.typeText(text)
        app.buttons["sendMessage"].tap()
    }

    // 1. Host: create space + channel, copy invite, post a message.
    func testHostCreateInviteAndPost() throws {
        let app = XCUIApplication()
        app.launch()
        login(app)
        app.buttons["Open Chat"].tap()
        app.buttons["installChat"].tap()
        XCTAssertTrue(app.buttons["chatAdd"].waitForExistence(timeout: 90), "install failed")

        app.buttons["chatAdd"].tap()
        app.buttons["New space"].tap()
        let sf = app.alerts.textFields.firstMatch
        XCTAssertTrue(sf.waitForExistence(timeout: 5)); sf.tap(); sf.typeText("shared")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["shared"].waitForExistence(timeout: 20)); app.staticTexts["shared"].tap()

        app.buttons["channelAdd"].tap()
        app.buttons["New channel"].tap()
        let cf = app.alerts.textFields.firstMatch
        XCTAssertTrue(cf.waitForExistence(timeout: 5)); cf.tap(); cf.typeText("general")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["general"].waitForExistence(timeout: 30))

        // create + copy invite (still on the channels list; Invite is in its menu)
        app.buttons["channelAdd"].tap()
        app.buttons["Invite people"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 15), "invite not generated")
        app.buttons["Copy"].tap()
        app.buttons["Done"].tap()

        // post a message the guest should see
        app.staticTexts["general"].tap()
        send(app, "hi from host")
        XCTAssertTrue(app.staticTexts["hi from host"].waitForExistence(timeout: 20))
    }

    // 3. Guest: auto-join via E2E_JOIN (invite from pasteboard), see host msg, reply.
    func testGuestJoinAndReply() throws {
        let app = XCUIApplication()
        let invite = UIPasteboard.general.string ?? ""
        XCTAssertFalse(invite.isEmpty, "no invite on the pasteboard")
        app.launchEnvironment["E2E_JOIN"] = invite
        app.launchEnvironment["E2E_NODE"] = "http://localhost:4011"  // guest talks to node B
        app.launch()
        login(app)
        app.buttons["Open Chat"].tap()
        // E2E_JOIN hook auto-installs + joins; wait for the shared space, then open.
        openChannel(app, space: "shared", channel: "general", timeout: 90)
        // cross-node sync: the host's message should arrive
        XCTAssertTrue(app.staticTexts["hi from host"].waitForExistence(timeout: 60), "host message did not sync")
        send(app, "hi from guest")
        XCTAssertTrue(app.staticTexts["hi from guest"].waitForExistence(timeout: 20))
    }

    // 4. Host: the guest's reply should sync back.
    func testHostSeesReply() throws {
        let app = XCUIApplication()
        app.launch()
        login(app)
        app.buttons["Open Chat"].tap()
        openChannel(app, space: "shared", channel: "general", timeout: 30)
        XCTAssertTrue(app.staticTexts["hi from guest"].waitForExistence(timeout: 60), "guest reply did not sync")
    }
}
