import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// What core moved between 0.11.0-rc.32 and rc.38.
///
/// rc.32 → rc.38 added `deny_unknown_fields` to **37** admin request structs
/// that had been permissive. Nothing about the SDK changed; what changed is
/// that every extra key it had been sending — tolerated and ignored for
/// releases — became a 400 or 422 for the whole call.
///
/// So this file is almost entirely request-shape: for each body, the EXACT key
/// set, because that is the only assertion that catches an extra key. A test
/// that checks the keys it cares about are present passes just as happily with
/// a fatal one alongside them.
///
/// Every expectation here was replayed against a live `merod 0.11.0-rc.38`
/// before it was written down; the status codes in the comments are measured,
/// not inferred.
final class Rc38SurfaceTests: XCTestCase {
    private var recorder: RequestRecorder!
    private var admin: AdminApi!

    override func setUp() {
        super.setUp()
        recorder = RequestRecorder()
        recorder.install()
        admin = AdminApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!,
                session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        recorder = nil
        admin = nil
        super.tearDown()
    }

    private func capture(_ call: () async throws -> Void) async -> CapturedRequest {
        try? await call()
        guard let last = recorder.requests.last else {
            XCTFail("no request captured")
            return CapturedRequest(method: "", path: "", query: nil, body: nil)
        }
        return last
    }

    private func jsonBody(_ req: CapturedRequest) -> [String: Any]? {
        guard let body = req.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    // MARK: - `upgradePolicy` stopped being ignored and started being fatal

    /// Measured: with `upgradePolicy` this is
    /// `400 unknown field 'upgradePolicy', expected one of 'applicationId',
    /// 'name', 'appKey', 'bytecodeId'`.
    ///
    /// The field was never read by any node — core#3485 removed the concept.
    /// It survived in this SDK because rc.32 silently dropped unknown keys, and
    /// a comment here asserted the opposite: that a released node "declares the
    /// field required and rejects a body without it". A live rc.38 accepts the
    /// body without it and refuses the body with it.
    func testCreateNamespaceSendsNoUpgradePolicy() async {
        let req = await capture {
            _ = try await self.admin.createNamespace(
                CreateNamespaceRequest(applicationId: "app-1", name: "Workspace"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/namespaces")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(
            Set(body.keys), ["applicationId", "name"],
            "an rc.38 node refuses the whole request over one extra key")
    }

    /// The deprecated shim still compiles and must still drop the argument —
    /// otherwise the source-compatibility overload reintroduces the 400 it
    /// exists to spare callers.
    func testDeprecatedUpgradePolicyInitDoesNotPutItOnTheWire() async {
        let req = await capture {
            _ = try await self.admin.createNamespace(
                CreateNamespaceRequest(
                    applicationId: "app-1", upgradePolicy: "LazyOnAccess", name: "Workspace"))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertFalse(
            body.keys.contains("upgradePolicy"),
            "the shim accepts the argument for source compatibility and must discard it")
        XCTAssertEqual(Set(body.keys), ["applicationId", "name"])
    }

    // MARK: - The subgroup route is not the group-create body

    /// `POST /admin-api/namespaces/{id}/groups` reads `groupName` and
    /// `visibility`. Measured: `name` is
    /// `422 unknown field 'name', expected 'groupName' or 'visibility'`, and so
    /// is `groupId`.
    ///
    /// Both of the fields this request used to carry were wrong, which means
    /// the only call that ever worked was the one that named nothing — the
    /// empty body. Naming the subgroup, the reason to pass a request at all,
    /// always failed.
    func testCreateGroupInNamespaceSendsGroupName() async {
        let req = await capture {
            _ = try await self.admin.createGroupInNamespace(
                "ns-1", request: CreateGroupInNamespaceRequest(groupName: "room"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/groups")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(body["groupName"] as? String, "room")
        XCTAssertEqual(Set(body.keys), ["groupName"])
    }

    func testCreateGroupInNamespaceCarriesVisibility() async {
        let req = await capture {
            _ = try await self.admin.createGroupInNamespace(
                "ns-1",
                request: CreateGroupInNamespaceRequest(groupName: "room", visibility: "open"))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["groupName", "visibility"])
        XCTAssertEqual(
            body["visibility"] as? String, "open",
            "lowercase — the node rejects other spellings")
    }

    /// Passing no request at all stays an empty object. This was the one shape
    /// that worked before, and it must keep working.
    func testCreateGroupInNamespaceWithoutRequestSendsEmptyObject() async {
        let req = await capture { _ = try await self.admin.createGroupInNamespace("ns-1") }
        XCTAssertEqual(Set((self.jsonBody(req) ?? [:]).keys), [])
    }

    // MARK: - Bodies that were already right, pinned so they stay right

    /// These were permissive at rc.32 and are `deny_unknown_fields` at rc.38.
    /// They happened to carry no extra key — which is luck until it is asserted.
    func testContextCreateCarriesNoProtocolOrAlias() async {
        let req = await capture {
            _ = try await self.admin.createContext(
                CreateContextRequest(
                    applicationId: "app-1", groupId: "g-1", initializationParams: [1, 2]))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["applicationId", "groupId", "initializationParams"])
        XCTAssertFalse(body.keys.contains("protocol"))
        XCTAssertFalse(body.keys.contains("alias"))
    }
}
