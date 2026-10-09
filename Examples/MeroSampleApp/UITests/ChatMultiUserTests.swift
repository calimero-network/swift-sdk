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
    /// The two nodes chat-multi-e2e.sh boots. Every role names its own node:
    /// `ExplorerUI` adopts the Info.plist `DefaultNodeURL` over the field's
    /// default on every launch, so a role that does not pass `E2E_NODE` talks to
    /// whatever that key happens to hold. Only the guest used to pass it, and
    /// the host and verify roles silently followed a stale LAN IP baked into the
    /// committed spec — the host role failed first, so the run never got far
    /// enough to show that the guest was fine.
    private static let hostNodeURL = "http://localhost:4001"  // node A
    private static let guestNodeURL = "http://localhost:4011"  // node B

    /// A fresh app handle pointed at `node`, plus any extra launch env.
    private func launch(node: String, env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["E2E_NODE"] = node
        // The app's login is Cloud only; the e2e harness signs in to its node
        // through the development hook instead (no fields in the UI).
        app.launchEnvironment["E2E_NODE_USER"] = "dev"
        app.launchEnvironment["E2E_NODE_PASS"] = "dev-password"
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    /// Signed in by the `E2E_NODE` development hook at launch.
    private func login(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["openChat"].waitForExistence(timeout: 20),
            "no explorer — app error: "
                + (app.otherElements["loginError"].exists
                    ? app.otherElements["loginError"].label : "<none shown>"))
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

    /// Tap a button by its center coordinate once it exists — robust against
    /// SwiftUI cards reporting "not hittable" mid-transition (e.g. the landing's
    /// Open Chat entry right after the login → explorer switch).
    private func tapButton(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "\(id) not found")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // 1. Host: create space + channel, copy invite, post a message.
    func testHostCreateInviteAndPost() throws {
        try AppE2ETests.skipUnlessChatAppIsPublished()
        let app = launch(node: Self.hostNodeURL)
        login(app)
        tapButton(app, "openChat")
        if app.buttons["installChat"].waitForExistence(timeout: 8) { tapButton(app, "installChat") }
        XCTAssertTrue(app.buttons["chatAdd"].waitForExistence(timeout: 240), "chat home did not load")

        tapButton(app, "chatAdd")
        app.buttons["New space"].tap()
        let sf = app.alerts.textFields.firstMatch
        XCTAssertTrue(sf.waitForExistence(timeout: 5)); sf.tap(); sf.typeText("shared")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["shared"].waitForExistence(timeout: 45)); app.staticTexts["shared"].tap()

        tapButton(app, "channelAdd")
        app.buttons["New channel"].tap()
        let cf = app.alerts.textFields.firstMatch
        XCTAssertTrue(cf.waitForExistence(timeout: 5)); cf.tap(); cf.typeText("general")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["general"].waitForExistence(timeout: 60))

        // create + copy invite (still on the channels list; Invite is in its menu)
        tapButton(app, "channelAdd")
        app.buttons["Invite people"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 45), "invite not generated")
        app.buttons["Copy"].tap()
        app.buttons["Done"].tap()

        // post a message the guest should see
        app.staticTexts["general"].tap()
        send(app, "hi from host")
        XCTAssertTrue(app.staticTexts["hi from host"].waitForExistence(timeout: 20))
    }

    // 3. Guest: auto-join via E2E_JOIN (invite from pasteboard), see host msg, reply.
    func testGuestJoinAndReply() throws {
        try AppE2ETests.skipUnlessChatAppIsPublished()
        let invite = UIPasteboard.general.string ?? ""
        XCTAssertFalse(invite.isEmpty, "no invite on the pasteboard")
        let app = launch(node: Self.guestNodeURL, env: ["E2E_JOIN": invite])
        login(app)
        tapButton(app, "openChat")
        // E2E_JOIN hook auto-installs + joins; wait for the shared space, then open.
        openChannel(app, space: "shared", channel: "general", timeout: 90)
        // cross-node sync: the host's message should arrive
        XCTAssertTrue(app.staticTexts["hi from host"].waitForExistence(timeout: 60), "host message did not sync")
        send(app, "hi from guest")
        XCTAssertTrue(app.staticTexts["hi from guest"].waitForExistence(timeout: 20))
    }

    // 4. Host: the guest's reply should sync back.
    func testHostSeesReply() throws {
        try AppE2ETests.skipUnlessChatAppIsPublished()
        let app = launch(node: Self.hostNodeURL)
        login(app)
        tapButton(app, "openChat")
        openChannel(app, space: "shared", channel: "general", timeout: 30)
        XCTAssertTrue(app.staticTexts["hi from guest"].waitForExistence(timeout: 60), "guest reply did not sync")
    }
}
