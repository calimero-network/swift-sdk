import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `validateToken` never throws, so it must say whether the node judged the
/// token at all: an app that keeps working offline treats "no answer" and
/// "refused" very differently.
final class TokenValidationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func auth(_ session: URLSession = MockURLProtocol.makeSession()) -> AuthApi {
        AuthApi(http: URLSessionHttpClient(baseURL: URL(string: "https://node.test")!, session: session))
    }

    private func answer(_ status: Int) {
        MockURLProtocol.setHandler { _ in .init(status: status, headers: [:], body: Data()) }
    }

    func testAnAcceptedToken() async {
        answer(200)
        let validation = await auth().validateToken("t")
        XCTAssertTrue(validation.valid)
        XCTAssertFalse(validation.isUnreachable)
    }

    func testARefusedTokenIsARefusal() async {
        answer(403)
        let validation = await auth().validateToken("t")
        XCTAssertFalse(validation.valid)
        XCTAssertFalse(validation.isUnreachable, "the node answered, and said no")
    }

    func testA5xxIsNoVerdict() async {
        answer(503)
        let validation = await auth().validateToken("t")
        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.isUnreachable)
        XCTAssertEqual(validation.status, 503)
    }

    func testNoNetworkIsNoVerdict() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        let validation = await auth(URLSession(configuration: config)).validateToken("t")
        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.isUnreachable)
        XCTAssertEqual(validation.status, 401, "unchanged for callers that read the status")
    }
}

/// Every request fails before reaching a server.
private final class NoNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
