import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Outbound approvals (core#4690): an app's outbound HTTPS request needs its
/// namespace's approval for the app's publisher. Admins approve on namespace
/// creation or group upgrade (`approveOutbound`), or set a publisher's list
/// directly on `/namespaces/{id}/outbound-approvals`.
///
/// Request tests pin the exact key set: every body here is `deny_unknown_fields`.
final class OutboundApprovalTests: XCTestCase {
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
        guard let body = req.body, !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Serve one fixed body to every request. Requests are still recorded.
    private func serve(_ json: String, status: Int = 200) {
        let recorder = self.recorder!
        MockURLProtocol.setHandler { req in
            recorder.append(req)
            return .init(
                status: status, headers: ["Content-Type": "application/json"],
                body: Data(json.utf8))
        }
    }

    private static let prefix = "https://api.example/v1/"
    private static let signer = "did:key:z6MkPublisher"

    // MARK: - OutboundSelection

    func testManifestEncodesAsTheBareKeyword() throws {
        let data = try JSONEncoder().encode(OutboundSelection.manifest)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""manifest""#)
    }

    func testPrefixesEncodeAsAnArrayOfStrings() throws {
        let data = try JSONEncoder().encode(OutboundSelection.prefixes([Self.prefix]))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String]
        XCTAssertEqual(decoded, [Self.prefix])
        let empty = try JSONEncoder().encode(OutboundSelection.prefixes([]))
        XCTAssertEqual(String(decoding: empty, as: UTF8.self), "[]")
    }

    func testSelectionDecodesTheKeywordAndAList() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(OutboundSelection.self, from: Data(#""manifest""#.utf8)), .manifest)
        XCTAssertEqual(
            try decoder.decode(OutboundSelection.self, from: Data(#"["\#(Self.prefix)"]"#.utf8)),
            .prefixes([Self.prefix]))
        XCTAssertEqual(try decoder.decode(OutboundSelection.self, from: Data("[]".utf8)), .prefixes([]))
    }

    func testSelectionRefusesAnyOtherStringOrShape() {
        let decoder = JSONDecoder()
        for json in [#""Manifest""#, #""all""#, #""""#, "42", #"{"prefixes":[]}"#, "[1]"] {
            XCTAssertThrowsError(try decoder.decode(OutboundSelection.self, from: Data(json.utf8)), json)
        }
    }

    // MARK: - Approving on create and upgrade

    func testCreateNamespaceOmitsApproveOutboundUnlessSet() async {
        var req = await capture {
            _ = try await self.admin.createNamespace(CreateNamespaceRequest(applicationId: "app-1"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/namespaces")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["applicationId"])

        req = await capture {
            _ = try await self.admin.createNamespace(
                CreateNamespaceRequest(applicationId: "app-1", approveOutbound: .manifest))
        }
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["applicationId", "approveOutbound"])
        XCTAssertEqual(jsonBody(req)?["approveOutbound"] as? String, "manifest")
    }

    func testUpgradeGroupSendsApproveOutboundPrefixes() async {
        var req = await capture {
            _ = try await self.admin.upgradeGroup("g-1", request: UpgradeGroupRequest(targetApplicationId: "app-2"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/upgrade")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["targetApplicationId"])

        req = await capture {
            _ = try await self.admin.upgradeGroup(
                "g-1",
                request: UpgradeGroupRequest(targetApplicationId: "app-2", approveOutbound: .prefixes([Self.prefix])))
        }
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["targetApplicationId", "approveOutbound"])
        XCTAssertEqual(jsonBody(req)?["approveOutbound"] as? [String], [Self.prefix])
    }

    func testCreateNamespaceResponseCarriesTheApproval() async throws {
        serve(
            """
            {"data":{"namespaceId":"ns-1","outboundApproval":{
              "signer":"\(Self.signer)","prefixes":["\(Self.prefix)"],
              "reviewed":["\(Self.prefix)","https://b.example/"]}}}
            """)
        let created = try await admin.createNamespace(
            CreateNamespaceRequest(applicationId: "app-1", approveOutbound: .manifest))
        XCTAssertEqual(created.namespaceId, "ns-1")
        XCTAssertEqual(
            created.outboundApproval,
            OutboundApproval(
                signer: Self.signer, prefixes: [Self.prefix], reviewed: [Self.prefix, "https://b.example/"]))
    }

    func testResponsesWithoutAnApprovalDecodeAsNil() async throws {
        serve(#"{"data":{"namespaceId":"ns-1"}}"#)
        let created = try await admin.createNamespace(CreateNamespaceRequest(applicationId: "app-1"))
        XCTAssertNil(created.outboundApproval)

        serve(#"{"data":{"groupId":"g-1","status":"in_progress"}}"#)
        let upgraded = try await admin.upgradeGroup("g-1", request: UpgradeGroupRequest(targetApplicationId: "a"))
        XCTAssertNil(upgraded.outboundApproval)
    }

    func testUpgradeGroupResponseCarriesTheApproval() async throws {
        serve(
            """
            {"data":{"groupId":"g-1","status":"in_progress","localContextsTotal":2,"localContextsSwapped":0,
              "localContextsFailed":0,"contextsTrialled":2,"contextsNotHeld":0,
              "outboundApproval":{"signer":"\(Self.signer)","prefixes":[],"reviewed":["\(Self.prefix)"]}}}
            """)
        let upgraded = try await admin.upgradeGroup(
            "g-1", request: UpgradeGroupRequest(targetApplicationId: "app-2", approveOutbound: .prefixes([])))
        XCTAssertEqual(
            upgraded.outboundApproval, OutboundApproval(signer: Self.signer, prefixes: [], reviewed: [Self.prefix]))
    }

    // MARK: - The namespace's list

    func testListOutboundApprovalsGetsTheNamespacesList() async throws {
        serve(
            """
            {"data":[{"signer":"\(Self.signer)","prefixes":["\(Self.prefix)"],"reviewed":["\(Self.prefix)"]},
                     {"signer":"did:key:other","prefixes":[],"reviewed":[]}]}
            """)
        let approvals = try await admin.listOutboundApprovals("ns-1")
        let req = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/outbound-approvals")
        XCTAssertEqual(
            approvals,
            [
                OutboundApproval(signer: Self.signer, prefixes: [Self.prefix], reviewed: [Self.prefix]),
                OutboundApproval(signer: "did:key:other", prefixes: [], reviewed: []),
            ])
    }

    func testSetOutboundApprovalPutsExactlyApplicationIdAndApprove() async {
        var req = await capture {
            _ = try await self.admin.setOutboundApproval(
                "ns-1", request: SetOutboundApprovalRequest(applicationId: "app-1", approve: .prefixes([Self.prefix])))
        }
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/outbound-approvals")
        var body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["applicationId", "approve"])
        XCTAssertEqual(body["applicationId"] as? String, "app-1")
        XCTAssertEqual(body["approve"] as? [String], [Self.prefix])

        req = await capture {
            _ = try await self.admin.setOutboundApproval(
                "ns-1", request: SetOutboundApprovalRequest(applicationId: "app-1", approve: .manifest))
        }
        body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["applicationId", "approve"])
        XCTAssertEqual(body["approve"] as? String, "manifest")
    }

    /// An empty list is how a publisher's approval is revoked, so it must go
    /// out as `[]`, never be dropped.
    func testRevokingSendsAnEmptyList() async {
        let req = await capture {
            _ = try await self.admin.setOutboundApproval(
                "ns-1", request: SetOutboundApprovalRequest(applicationId: "app-1", approve: .prefixes([])))
        }
        XCTAssertEqual((jsonBody(req)?["approve"] as? [String])?.isEmpty, true)
    }

    /// Core flattens the approval's fields beside `namespaceId` and `published`.
    func testSetOutboundApprovalDecodesTheFlattenedResponse() async throws {
        serve(
            """
            {"data":{"namespaceId":"ns-1","signer":"\(Self.signer)","prefixes":["\(Self.prefix)"],
              "reviewed":["\(Self.prefix)"],"published":true}}
            """)
        let set = try await admin.setOutboundApproval(
            "ns-1", request: SetOutboundApprovalRequest(applicationId: "app-1", approve: .prefixes([Self.prefix])))
        XCTAssertEqual(set.namespaceId, "ns-1")
        XCTAssertTrue(set.published)
        XCTAssertEqual(
            set.approval, OutboundApproval(signer: Self.signer, prefixes: [Self.prefix], reviewed: [Self.prefix]))

        serve(
            """
            {"data":{"namespaceId":"ns-1","signer":"\(Self.signer)","prefixes":[],"reviewed":[],"published":false}}
            """)
        let unchanged = try await admin.setOutboundApproval(
            "ns-1", request: SetOutboundApprovalRequest(applicationId: "app-1", approve: .prefixes([])))
        XCTAssertFalse(unchanged.published)
        XCTAssertTrue(unchanged.prefixes.isEmpty)
    }
}
