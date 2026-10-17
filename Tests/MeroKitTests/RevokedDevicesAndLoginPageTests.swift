import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// `GET /admin-api/namespaces/:id/revoked-devices` (core
/// `handlers/namespaces/revoked_devices.rs`) and `GET /auth/login` (core
/// `auth/src/api/routes.rs`).
final class RevokedDevicesAndLoginPageTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func serve(contentType: String, _ body: String) -> RequestRecorder {
        let recorded = RequestRecorder()
        MockURLProtocol.setHandler { req in
            recorded.append(req)
            return .init(status: 200, headers: ["Content-Type": contentType], body: Data(body.utf8))
        }
        return recorded
    }

    private var http: URLSessionHttpClient {
        URLSessionHttpClient(baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession())
    }

    /// The handler serializes the payload directly: no `{ data }` envelope.
    func testListNamespaceRevokedDevicesReadsTheTopLevelBody() async throws {
        let device = String(repeating: "a", count: 64)
        let recorded = serve(
            contentType: "application/json", #"{"revokedDevices":["\#(device)"],"withdrawnSlots":[]}"#)
        let result = try await AdminApi(http: http).listNamespaceRevokedDevices("ns1")
        XCTAssertEqual(result, NamespaceRevokedDevices(revokedDevices: [device], withdrawnSlots: []))
        XCTAssertEqual(recorded.requests.first?.method, "GET")
        XCTAssertEqual(recorded.requests.first?.path, "/admin-api/namespaces/ns1/revoked-devices")
    }

    func testGetLoginPageReturnsTheHTML() async throws {
        let recorded = serve(contentType: "text/html", "<!doctype html><title>Login</title>")
        let page = try await AuthApi(http: http).getLoginPage()
        XCTAssertEqual(page, "<!doctype html><title>Login</title>")
        XCTAssertEqual(recorded.requests.first?.method, "GET")
        XCTAssertEqual(recorded.requests.first?.path, "/auth/login")
    }
}
