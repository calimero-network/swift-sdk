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
}
