import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A `403` on `/sse` ends the stream with an error instead of reconnecting
/// every 3 s forever.
final class SseForbiddenTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func firstError(headers: [String: String]) async -> Error? {
        MockURLProtocol.setHandler { _ in
            .init(status: 403, headers: headers, body: Data(#"{"error":"forbidden"}"#.utf8))
        }
        let sse = SseClient(
            baseURL: URL(string: "https://node.test")!, token: { "tok" }, session: MockURLProtocol.makeSession())
        do {
            for try await _ in sse.events(contextIds: ["ctx"]) {}
            XCTFail("stream finished without an error")
            return nil
        } catch {
            return error
        }
    }

    func testForbiddenConnectFinishesTheStream() async {
        let error = await firstError(headers: [:]) as? MeroError
        XCTAssertEqual(error?.httpStatus, 403)
        if case .http = error {} else { XCTFail("expected .http, got \(String(describing: error))") }
    }

    func testRevokedFamilyIsNamed() async {
        let error = await firstError(headers: ["x-auth-error": "token_revoked"]) as? MeroError
        guard case .authRevoked(let reason, let http)? = error else {
            return XCTFail("expected .authRevoked, got \(String(describing: error))")
        }
        XCTAssertEqual(reason, "token_revoked")
        XCTAssertEqual(http.status, 403)
    }
}
