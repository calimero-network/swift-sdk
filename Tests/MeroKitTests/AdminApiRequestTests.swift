import XCTest

@testable import MeroKit

/// Asserts that representative ``AdminApi`` methods issue the exact HTTP verb,
/// path, and body the core admin API expects. Responses are intentionally
/// benign — we capture and assert the *request*, then ignore the decode result.
final class AdminApiRequestTests: XCTestCase {
    private var recorder: RequestRecorder!
    private var admin: AdminApi!

    override func setUp() {
        super.setUp()
        recorder = RequestRecorder()
        recorder.install()
        let http = URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!,
            session: MockURLProtocol.makeSession()
        )
        admin = AdminApi(http: http)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        recorder = nil
        admin = nil
        super.tearDown()
    }

    /// Run an admin call, ignoring any decode error, and return the last request seen.
    private func capture(_ call: () async throws -> Void) async -> CapturedRequest {
        try? await call()
        guard let last = recorder.requests.last else {
            XCTFail("no request captured")
            return CapturedRequest(method: "", path: "", query: nil, body: nil)
        }
        return last
    }

    func testContextEndpoints() async {
        var req = await capture { _ = try await self.admin.getContexts() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/contexts")

        req = await capture { _ = try await self.admin.getContext("ctx-1") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1")

        req = await capture { _ = try await self.admin.deleteContext("ctx-1") }
        XCTAssertEqual(req.method, "DELETE")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1")

        req = await capture { _ = try await self.admin.getContextIdentities("ctx-1") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/identities")

        req = await capture { _ = try await self.admin.joinContext("ctx-1") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/join")
    }

    func testCreateContextBody() async {
        let request = CreateContextRequest(applicationId: "app-1", groupId: "grp-1", name: "My Context")
        let req = await capture { _ = try await self.admin.createContext(request) }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/contexts")
        let body = req.jsonBody
        XCTAssertEqual(body?["applicationId"] as? String, "app-1")
        XCTAssertEqual(body?["groupId"] as? String, "grp-1")
        XCTAssertEqual(body?["name"] as? String, "My Context")
    }

    func testApplicationAndBlobEndpoints() async {
        var req = await capture { _ = try await self.admin.listApplications() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/applications")

        req = await capture { _ = try await self.admin.listBlobs() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/blobs")

        req = await capture { _ = try await self.admin.getBlobInfo("blob-1") }
        XCTAssertEqual(req.method, "HEAD")
        XCTAssertEqual(req.path, "/admin-api/blobs/blob-1")
    }

    func testAliasEndpoints() async {
        let req = await capture {
            _ = try await self.admin.lookupContextAlias("my-alias")
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/alias/lookup/context/my-alias")
    }
}

// MARK: - Recorder

struct CapturedRequest: Sendable {
    let method: String
    let path: String
    let query: String?
    let body: Data?

    var jsonBody: [String: Any]? {
        guard let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj
    }
}

/// Captures every request on ``MockURLProtocol`` and returns a benign 200.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [CapturedRequest] = []

    var requests: [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func install() {
        MockURLProtocol.setHandler { [weak self] req in
            let captured = CapturedRequest(
                method: req.httpMethod ?? "GET",
                path: req.url?.path ?? "",
                query: req.url?.query,
                body: FakeNode.body(req)
            )
            self?.record(captured)
            // Benign envelope; individual methods may fail to decode it — that's fine,
            // these tests assert the request, not the response.
            return .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8))
        }
    }

    private func record(_ request: CapturedRequest) {
        lock.lock(); _requests.append(request); lock.unlock()
    }
}
