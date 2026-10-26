import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// Fast, simulator-free tests of the SwiftUI frontend's view-model. The actual
/// on-screen flow is covered by the XCUITest suite in Examples/MeroSampleApp.
@MainActor
final class MeroClientTests: XCTestCase {
    private var node: FakeNode!

    override func setUp() {
        super.setUp()
        node = FakeNode()
        node.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        node = nil
        super.tearDown()
    }

    private func makeClient() -> MeroClient {
        MeroClient(session: MockURLProtocol.makeSession())
    }

    func testLoginSuccessPublishesAuthenticated() async {
        let client = makeClient()
        XCTAssertFalse(client.isAuthenticated)

        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(client.username, "dev")
        XCTAssertEqual(client.nodeURL, "https://node.test")
        XCTAssertNil(client.errorMessage)
    }

    func testLoginValidatesInput() async {
        let client = makeClient()

        await client.login(nodeURL: "not a url", username: "dev", password: "pw")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNotNil(client.errorMessage)

        await client.login(nodeURL: "https://node.test", username: "", password: "")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNotNil(client.errorMessage)
    }

    func testLoginRefusesPlainHttpAcrossTheNetwork() async {
        let client = makeClient()
        await client.login(nodeURL: "http://node.test", username: "dev", password: "pw")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(client.errorMessage, MeroClient.insecureNodeURLMessage)
    }

    func testLogoutClearsState() async {
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        XCTAssertTrue(client.isAuthenticated)

        await client.logout()
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(client.username, "")
        XCTAssertNil(client.lastRpcResult)
    }

    func testSampleRpcPublishesResult() async {
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")

        await client.runSampleRpc(contextId: "ctx", method: "get")
        XCTAssertEqual(client.lastRpcResult, "number(42.0)")
        XCTAssertNil(client.errorMessage)
    }

    func testRevokedSessionSurfacesFriendlyError() async {
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        node.revokeFamily()

        await client.runSampleRpc(contextId: "ctx", method: "get")
        XCTAssertNotNil(client.errorMessage)
    }

    // MARK: - Login failures, told apart

    private func answerLogin(_ status: Int, headers: [String: String] = [:]) {
        MockURLProtocol.setHandler { _ in .init(status: status, headers: headers, body: Data()) }
    }

    func testAWrongPasswordIsInvalidCredentials() async {
        answerLogin(401)
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "nope")
        XCTAssertEqual(client.loginFailure, .invalidCredentials)
        XCTAssertEqual(client.errorMessage, "Login failed — check your credentials and node URL.")
    }

    func testALockoutIsToldApartFromAWrongPassword() async {
        answerLogin(429, headers: ["Retry-After": "42"])
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(client.loginFailure, .rateLimited(retryAfter: 42))
        XCTAssertEqual(client.errorMessage, "Too many failed attempts. Try again in 42 seconds.")
    }

    func testAMissingNodeIsNotFound() async {
        answerLogin(404)
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        XCTAssertEqual(client.loginFailure, .notFound)
        XCTAssertEqual(client.errorMessage, "No sign-in found at that address — check the node URL.")
    }

    func testASuccessfulLoginClearsTheLastFailure() async {
        answerLogin(401)
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "nope")
        XCTAssertNotNil(client.loginFailure)
        node.install()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertNil(client.loginFailure)
        XCTAssertNil(client.errorMessage)
    }

    func testClearErrorClearsTheFailure() async {
        answerLogin(401)
        let client = makeClient()
        await client.login(nodeURL: "https://node.test", username: "dev", password: "nope")
        client.clearError()
        XCTAssertNil(client.loginFailure)
        XCTAssertNil(client.errorMessage)
    }

    // MARK: - Error words

    func testTheNetworkMessageNamesNoVendor() {
        let offline = MeroError.network("The Internet connection appears to be offline.")
        let message = MeroClient.defaultMessage(for: offline)
        XCTAssertEqual(message, "Can't connect to the server: The Internet connection appears to be offline.")
        XCTAssertFalse(message.contains("Calimero"))
    }

    func testErrorMessagesCanBeReplaced() async {
        answerLogin(429, headers: ["Retry-After": "5"])
        let client = makeClient()
        client.errorMessages = { error in
            if case .rateLimited? = Optional(LoginFailureReason(error)) { return "Locked. Wait a moment." }
            return nil
        }
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        XCTAssertEqual(client.errorMessage, "Locked. Wait a moment.")

        answerLogin(401)
        await client.login(nodeURL: "https://node.test", username: "dev", password: "pw")
        XCTAssertEqual(
            client.errorMessage, "Login failed — check your credentials and node URL.",
            "nil keeps the built-in message")
    }
}
