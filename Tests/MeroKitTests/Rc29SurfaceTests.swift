import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The admin-API surface core moved between 0.11.0-rc.26 and rc.29.
///
/// Two halves, deliberately. The **request** half pins verb and path, which is
/// what the existing suite already does. The **response** half decodes bodies
/// captured verbatim from a live rc.29 node — because a request-only test cannot
/// catch a response-shape break, and that is precisely how `joinNamespace`
/// shipped broken against rc.25: every test asserted the request and none
/// decoded a realistic reply.
///
/// Three of these endpoints return their payload FLAT rather than under
/// `data`, which is not guessable and is the kind of thing only a real body
/// settles.
final class Rc29SurfaceTests: XCTestCase {
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

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Fixture.decode(type, name)
    }

    // MARK: - Node identity  (replaces the namespace-identity route rc.23 deleted)

    /// Captured verbatim from a live core 0.11.0-rc.29 node.
    private static let identityBody = "rc29-node-identity"

    func testGetNodeIdentityRequest() async {
        let req = await capture { _ = try await self.admin.getNodeIdentity() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/identity")
    }

    func testGetNodeIdentityDecodesALiveNodeResponse() throws {
        let wrapper = try fixture(ApiResponse<NodeIdentity>.self, Self.identityBody)
        let identity = try XCTUnwrap(wrapper.data)
        // The whole reason to call this: an account id and a device key are BOTH
        // 64 hex since rc.27 removed base58, so only provenance separates them.
        XCTAssertEqual(identity.accountId.count, 64)
        XCTAssertEqual(identity.deviceId?.count, 64)
        XCTAssertNotEqual(
            identity.accountId, identity.deviceId,
            "the account and the device must not be the same id — that is the swap "
                + "nothing else can detect")
        XCTAssertEqual(identity.publicKey.count, 64)
        XCTAssertEqual(identity.accountRootPublicKey.count, 64)
        XCTAssertEqual(identity.deviceAgreementKey?.count, 64)
    }

    // MARK: - Application ABI

    func testGetApplicationAbiRequest() async {
        var req = await capture { _ = try await self.admin.getApplicationAbi("app-1") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/applications/app-1/abi")

        // A multi-service bundle needs the service named; a single-wasm app must
        // NOT send the param (core matches it exactly against the manifest).
        req = await capture {
            _ = try await self.admin.getApplicationAbi("app-1", serviceName: "logic")
        }
        XCTAssertEqual(req.query, "service_name=logic")
    }

    // MARK: - Intents

    func testPerformIntentRequest() async {
        let req = await capture {
            _ = try await self.admin.performIntent(
                "ctx-1",
                request: PerformIntentRequest(
                    method: "set", argsJson: ["key": "k"], warrant: "w", authorProof: "p"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/intents")
        let body = jsonBody(req)
        XCTAssertEqual(body?["method"] as? String, "set")
        XCTAssertEqual(body?["warrant"] as? String, "w")
        XCTAssertEqual(body?["authorProof"] as? String, "p")
    }

    // MARK: - Direct admission  (new in rc.29)

    func testAdmitJoinRequest() async {
        let invitation = SignedGroupOpenInvitation(
            invitation: GroupInvitationFromAdmin(
                inviterIdentity: [1], groupId: [2], expirationTimestamp: 3, secretSalt: [4],
                admitters: ["ab"]),
            inviterSignature: "sig")
        let req = await capture {
            _ = try await self.admin.admitJoin(
                "ns-1", request: AdmitJoinRequest(invitation: invitation, signedOp: "deadbeef"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/admit")
        let body = jsonBody(req)
        XCTAssertEqual(body?["signedOp"] as? String, "deadbeef")
        // A live rc.29 node answers a body without this exactly
        // "missing field `invitation`", so the key name is load-bearing.
        let signed = body?["invitation"] as? [String: Any]
        XCTAssertNotNil(signed)
        let inner = signed?["invitation"] as? [String: Any]
        XCTAssertEqual(inner?["admitters"] as? [String], ["ab"])
    }

    func testAdmitJoinResponseIsPublishedNotJoined() throws {
        let wrapper = try decode(
            ApiResponse<AdmitJoinResponseData>.self, #"{"data":{"published":true}}"#)
        XCTAssertEqual(try XCTUnwrap(wrapper.data).published, true)
    }

    // MARK: - Group member devices  (FLAT response)

    /// Captured verbatim from a live core 0.11.0-rc.29 node.
    private static let memberDevicesBody = "rc29-member-devices"

    func testListMemberDevicesRequest() async {
        var req = await capture { _ = try await self.admin.listMemberDevices("g-1") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/member-devices")
        XCTAssertNil(req.query, "no paging params unless asked for")

        req = await capture {
            _ = try await self.admin.listMemberDevices("g-1", offset: 10, limit: 5)
        }
        XCTAssertEqual(req.query, "offset=10&limit=5")
    }

    func testListMemberDevicesDecodesALiveNodeResponse() throws {
        // FLAT, not under `data`.
        let response = try fixture(ListMemberDevicesResponseData.self, Self.memberDevicesBody)
        let member = try XCTUnwrap(response.members.first)
        XCTAssertEqual(member.account.count, 64)
        let device = try XCTUnwrap(member.devices.first)
        XCTAssertEqual(device.deviceId.count, 64)
        XCTAssertEqual(device.signingKey.count, 64)
        // The distinction this endpoint exists for: same member, two different
        // id kinds, and `addGroupMembers` wants the device while every role
        // grant wants the account.
        XCTAssertNotEqual(member.account, device.deviceId)
    }

    // MARK: - Account devices and applications  (FLAT responses)

    /// Captured verbatim from a live core 0.11.0-rc.29 node.
    private static let accountDevicesBody = "rc29-account-devices"
    /// Captured verbatim from a live core 0.11.0-rc.29 node.
    private static let accountApplicationsBody = "rc29-account-applications"

    func testAccountListingRequests() async {
        var req = await capture { _ = try await self.admin.listAccountDevices() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/account/devices")

        req = await capture { _ = try await self.admin.listAccountApplications() }
        XCTAssertEqual(req.path, "/admin-api/account/applications")
    }

    func testListAccountDevicesDecodesALiveNodeResponse() throws {
        let response = try fixture(AccountDevicesResponse.self, Self.accountDevicesBody)
        let device = try XCTUnwrap(response.devices.first)
        XCTAssertTrue(device.isSelf)
        XCTAssertFalse(device.revoked)
        XCTAssertEqual(device.deviceId.count, 64)
        XCTAssertEqual(device.namespaces.count, 1)
    }

    func testListAccountApplicationsDecodesALiveNodeResponse() throws {
        let response = try fixture(
            AccountApplicationsResponse.self, Self.accountApplicationsBody)
        let entry = try XCTUnwrap(response.applications.first)
        XCTAssertEqual(entry.applicationId.count, 64)
        XCTAssertEqual(entry.namespaces.first?.count, 64)
    }

    // MARK: - Pairing, relink, revoke
    //
    // rc.28 moved pairing off the namespace: a device pairs to an ACCOUNT once
    // and is then linked into namespaces. Revocation stayed per-namespace,
    // because that is where the group key gets rotated.

    func testPairingRequestsAreAccountScopedNotNamespaceScoped() async {
        var req = await capture {
            _ = try await self.admin.accountPairInit(
                AccountPairInitRequest(accountRootPublicKey: "root", namespaces: ["ns-1"]))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/account/pair-init")

        req = await capture {
            _ = try await self.admin.accountPairComplete(
                AccountPairCompleteRequest(
                    deviceId: "d-1", kemPublicKey: "kem", signPublicKey: "sign",
                    statement: "st", confirmationCode: "1234"))
        }
        XCTAssertEqual(req.path, "/admin-api/account/pair-complete")

        req = await capture { _ = try await self.admin.relinkDevice("d-1") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/account/devices/d-1/relink")

        req = await capture {
            _ = try await self.admin.revokeDevice(
                "ns-1", request: RevokeDeviceRequest(deviceId: "d-1"))
        }
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/account/revoke")
    }

    func testRelinkResponseCarriesWhatItSkippedAndWhy() throws {
        let wrapper = try decode(
            ApiResponse<RelinkDeviceResponseData>.self,
            #"""
            {"data":{"accountId":"a","deviceId":"d","applications":["app"],
             "linkedIn":[{"namespaceId":"ns-1","keyDelivered":true}],
             "skipped":[{"namespaceId":"ns-2","reason":"not a member"}]}}
            """#)
        let data = try XCTUnwrap(wrapper.data)
        XCTAssertEqual(data.linkedIn.first?.keyDelivered, true)
        // A relink that "did nothing" is usually a full `skipped` list rather
        // than a failure, so this is the field a caller has to read.
        XCTAssertEqual(data.skipped.first?.reason, "not a member")
    }

    func testRevokeResponseSaysWhereTheKeyRotated() throws {
        let wrapper = try decode(
            ApiResponse<RevokeDeviceResponseData>.self,
            #"""
            {"data":{"accountId":"a","deviceId":"d","keyRotated":true,
             "revokedIn":[{"namespaceId":"ns-1","keyRotated":true}]}}
            """#)
        let data = try XCTUnwrap(wrapper.data)
        XCTAssertTrue(data.keyRotated)
        XCTAssertEqual(data.revokedIn.first?.namespaceId, "ns-1")
    }

    // MARK: - Readiness

    func testReadinessIsItsOwnEndpoint() async {
        let req = await capture { _ = try await self.admin.readinessCheck() }
        XCTAssertEqual(req.path, "/admin-api/ready")
    }

    // MARK: - admitters on the two invitation requests

    func testInvitationRequestsCarryAdmittersOnlyWhenNamed() async throws {
        // Omitted when empty: a node older than rc.29 rejects the field, and
        // core picks a better default than [] anyway (the group's admins).
        var req = await capture {
            _ = try await self.admin.createNamespaceInvitation("ns-1")
        }
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/invite")

        req = await capture {
            _ = try await self.admin.createNamespaceInvitation(
                "ns-1", request: CreateNamespaceInvitationRequest(expirationTimestamp: 99))
        }
        var body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(req.body)) as? [String: Any])
        XCTAssertNil(body["admitters"], "an empty list must not be sent")
        XCTAssertEqual(body["expirationTimestamp"] as? Int, 99)

        let account = String(repeating: "a", count: 64)
        req = await capture {
            _ = try await self.admin.createGroupInvitation(
                "g-1", request: CreateGroupInvitationRequest(admitters: [account]))
        }
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/invite")
        body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(req.body)) as? [String: Any])
        XCTAssertEqual(body["admitters"] as? [String], [account])
    }
}
