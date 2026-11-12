import Foundation
import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// A consent page answered in-process: sends the person back with `result`,
/// or is dismissed.
private struct Browser: WebAuthenticating {
    let result: String?
    let opened = Box<[URL]>([])

    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        opened.update { $0.append(url) }
        guard let result else { throw WebAuthenticationCancelled() }
        return URL(string: "\(callback.url)?request_id=r1&result=\(result)")!
    }
}

/// `ConsentLauncher.begin`: the auth session with an https callback, and the
/// browser plus polling where the system has no https callback.
@MainActor
final class ConsentLauncherTests: XCTestCase {
    private static let callback = CloudCallback.https(host: "chat.example", path: "/consent")
    nonisolated(unsafe) private var node: FakeCloudNode!
    nonisolated(unsafe) private var decision: Box<JSONValue>!

    override func setUp() {
        super.setUp()
        let decision = Box<JSONValue>([
            "requestId": "r1", "kind": "createOrg", "status": "approved", "decidedAt": 2, "outcome": ["orgId": "o9"],
        ])
        self.decision = decision
        node = FakeCloudNode { request in
            switch request.path {
            case "/consent/requests":
                return .json([
                    "requestId": "r1", "url": "https://node.test/consent/r1", "expiresAt": 1_900_000_000,
                    "code": .string(confirmationCode("r1")),
                ])
            case "/consent/r1/result": return .json(decision.get)
            default: return .error(404, "NOT_FOUND")
            }
        }
        node.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> CalimeroClient {
        CalimeroClient(
            CalimeroClientOptions(
                baseUrl: "https://node.test", policy: CloudPolicy(allowMock: true),
                session: MockURLProtocol.makeSession()))
    }

    func testRunsThePageInTheAuthSessionWithAnHTTPSCallback() async throws {
        let browser = Browser(result: "approved")
        let decision = try await ConsentLauncher.begin(
            client: client(), ask: .createOrg(name: "Acme"), callback: Self.callback, opener: browser,
            openInBrowser: { _ in
                XCTFail("the auth session takes an https callback here")
                return false
            },
            httpsCallbackSupported: true)
        XCTAssertEqual(decision.orgId, "o9")
        XCTAssertEqual(browser.opened.get, [URL(string: "https://node.test/consent/r1")!])
        let body = try XCTUnwrap(node.requests.first { $0.path == "/consent/requests" }?.json)
        XCTAssertEqual(body["returnTo"], "https://chat.example/consent")
    }

    func testFallsBackToTheBrowserAndPollsOnAnOlderSystem() async throws {
        let browser = Browser(result: "approved")
        let opened = Box<[URL]>([])
        let decision = try await ConsentLauncher.begin(
            client: client(), ask: .createOrg(name: "Acme"), callback: Self.callback, opener: browser,
            openInBrowser: { url in
                opened.update { $0.append(url) }
                return true
            },
            httpsCallbackSupported: false)
        XCTAssertEqual(decision.orgId, "o9")
        XCTAssertEqual(opened.get, [URL(string: "https://node.test/consent/r1")!])
        XCTAssertTrue(browser.opened.get.isEmpty, "no auth session without an https callback")
    }

    func testADismissedSheetBeforeADecisionIsCancelled() async throws {
        decision.update { $0 = ["requestId": "r1", "kind": "createOrg", "status": "pending", "decidedAt": .null] }
        do {
            _ = try await ConsentLauncher.begin(
                client: client(), ask: .createOrg(name: "Acme"), callback: Self.callback,
                opener: Browser(result: nil), httpsCallbackSupported: true)
            XCTFail("expected WebAuthenticationCancelled")
        } catch is WebAuthenticationCancelled {}
    }

    func testDecliningToOpenThePageSendsNothingMore() async throws {
        let browser = Browser(result: "approved")
        let shown = Box<String?>(nil)
        do {
            _ = try await ConsentLauncher.begin(
                client: client(), ask: .acceptInvite(token: "inv_x"), callback: Self.callback, opener: browser,
                httpsCallbackSupported: true,
                confirm: { started in
                    shown.update { $0 = started.code }
                    return false
                })
            XCTFail("expected WebAuthenticationCancelled")
        } catch is WebAuthenticationCancelled {}
        XCTAssertEqual(shown.get, confirmationCode("r1"))
        XCTAssertTrue(browser.opened.get.isEmpty)
    }
}
