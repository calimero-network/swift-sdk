import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// What core moved between 0.11.0-rc.41 and rc.83.
///
/// Unlike rc.38→rc.41, this window took things away:
/// - `GET /certificate` and `POST /tee/verify-quote` are gone, so this SDK no
///   longer has `getCertificate` or `teeVerifyQuote`.
/// - `POST /groups` refuses a `groupId` (ids are derived now).
/// - An absent subgroup `visibility` now means `open`, not `restricted`.
/// - Every rc.41 token is dead: claims gained a required `key_id`.
///
/// And it added a lot: account-session reads, delegated intents, root-guarded
/// owner ops, the signed-release TEE policy, `/auth/logout`, group-keyed SSE
/// subscriptions and the `ReadOnlyWriteRefused` JSON-RPC error.
///
/// Response fixtures are core's own `crates/server/primitives/fixtures/wire/`
/// files at rc.83, copied verbatim as `Fixtures/rc83-*.json`. Request tests
/// pin the exact key set, because every body here is `deny_unknown_fields`.
final class Rc83SurfaceTests: XCTestCase {
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

    /// Serve one fixed body to every request, for the decode half of the file.
    /// Requests are still recorded.
    private func serve(_ json: String, status: Int = 200) {
        let recorder = self.recorder!
        MockURLProtocol.setHandler { req in
            recorder.append(req)
            return .init(
                status: status, headers: ["Content-Type": "application/json"],
                body: Data(json.utf8))
        }
    }

    private static let proof = String(repeating: "ab", count: 40)

    // MARK: - Removed and changed request bodies

    /// `groupId` is not a field any more, and the typed body cannot carry one.
    func testCreateGroupTypedBodyCarriesNoGroupId() async {
        let req = await capture {
            _ = try await self.admin.createGroup(
                CreateGroupRequest(applicationId: "app-1", name: "team"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/groups")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["applicationId", "name"])
    }

    /// rc.83 made an absent `visibility` create an OPEN subgroup. The SDK keeps
    /// the old meaning by always naming one.
    func testCreateGroupInNamespaceSendsRestrictedWhenNoneIsNamed() async {
        var req = await capture { _ = try await self.admin.createGroupInNamespace("ns-1") }
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/groups")
        XCTAssertEqual(jsonBody(req)?["visibility"] as? String, "restricted")

        req = await capture {
            _ = try await self.admin.createGroupInNamespace(
                "ns-1", request: CreateGroupInNamespaceRequest(groupName: "room"))
        }
        XCTAssertEqual(jsonBody(req)?["visibility"] as? String, "restricted")
        XCTAssertEqual(jsonBody(req)?["groupName"] as? String, "room")
    }

    func testCreateGroupInNamespaceKeepsAnExplicitOpen() async {
        let req = await capture {
            _ = try await self.admin.createGroupInNamespace(
                "ns-1", request: CreateGroupInNamespaceRequest(groupName: "lobby", visibility: "open"))
        }
        XCTAssertEqual(jsonBody(req)?["visibility"] as? String, "open")
    }

    /// The new flags are sent only when set, so a plain attest is the exact
    /// body an older node accepts.
    func testTeeAttestSendsFlagsOnlyWhenSet() async {
        var req = await capture { _ = try await self.admin.teeAttest(TeeAttestRequest(nonce: "00")) }
        XCTAssertEqual(req.path, "/admin-api/tee/attest")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["nonce"])

        req = await capture {
            _ = try await self.admin.teeAttest(
                TeeAttestRequest(nonce: "00", bindTransportKey: true, includeCollateral: true))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["nonce", "bindTransportKey", "includeCollateral"])
        XCTAssertEqual(body["bindTransportKey"] as? Bool, true)
    }

    func testTeeAttestResponseCarriesTheTransportKeyAndCollateral() async throws {
        serve(
            """
            {"data":{"quoteB64":"cXVvdGU=","quote":{
              "header":{"version":4,"attestationKeyType":2,"teeType":129,"qeVendorId":"aa","userData":"bb"},
              "body":{"tdxVersion":"1.5","teeTcbSvn":"00","mrseam":"00","mrsignerseam":"00","seamattributes":"00",
                "tdattributes":"00","xfam":"00","mrtd":"11","mrconfigid":"00","mrowner":"00","mrownerconfig":"00",
                "rtmr0":"00","rtmr1":"00","rtmr2":"00","rtmr3":"00","reportdata":"00"},
              "signature":"ss","attestationKey":"kk","certificationData":null},
             "transportPublicKey":"7070","collateral":{"tcbInfo":"{}"}}}
            """)
        let data = try await admin.teeAttest(TeeAttestRequest(nonce: "00", bindTransportKey: true))
        XCTAssertEqual(data.transportPublicKey, "7070")
        XCTAssertNotNil(data.collateral)
        XCTAssertNil(data.boundPublicKey, "not asked for, so not sent")
    }

    func testRegistrationAttestPostsTheNonce() async {
        let req = await capture {
            _ = try await self.admin.teeRegistrationAttest(TeeRegistrationAttestRequest(nonce: "ab"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/tee/registration-attest")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["nonce"])
    }

    // MARK: - TEE admission policy, both arms

    /// Core's own request fixture is the signed-release arm with a root proof.
    /// The SDK's factory has to produce exactly its key set.
    func testSignedReleasePolicyMatchesCoresFixture() async throws {
        let fixture = try Fixture.object("rc83-groups-tee-admission-policy-req")
        let req = await capture {
            try await self.admin.setTeeAdmissionPolicy(
                "g-1",
                request: .signedRelease(
                    SignedReleaseTeePolicy(allowedProfiles: ["locked-read-only"], minReleaseVersion: "2.3.72"),
                    allowedTcbStatuses: ["UpToDate"], mode: .relay, rootProof: Self.proof))
        }
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/settings/tee-admission-policy")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), Set(fixture.keys))
        XCTAssertEqual(body["mode"] as? String, "relay")
        XCTAssertEqual(body["allowedMrtd"] as? [String], [], "the signed-release arm sends every list empty")
        let release = body["signedRelease"] as? [String: Any] ?? [:]
        XCTAssertEqual(release["allowedProfiles"] as? [String], ["locked-read-only"])
    }

    func testMeasurementPolicyOmitsTheSignedReleaseArm() async {
        let req = await capture {
            try await self.admin.setTeeAdmissionPolicy(
                "g-1",
                request: .measurement(
                    allowedMrtd: ["m"], allowedRtmr1: ["r1"], allowedRtmr2: ["r2"], allowedRtmr3: ["r3"],
                    allowedTcbStatuses: ["UpToDate"]))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(
            Set(body.keys),
            [
                "allowedMrtd", "allowedRtmr0", "allowedRtmr1", "allowedRtmr2", "allowedRtmr3",
                "allowedTcbStatuses", "acceptMock",
            ])
        XCTAssertEqual(body["allowedRtmr3"] as? [String], ["r3"])
    }

    /// Core serves this one flat, with `enabled`, `mode` and `signedRelease`.
    func testAdmissionPolicyResponseDecodesTheSignedReleaseForm() async throws {
        serve(try Fixture.json("rc83-groups-tee-admission-policy-res"))
        let policy = try await admin.getTeeAdmissionPolicy("g-1")
        XCTAssertEqual(policy.enabled, true)
        XCTAssertEqual(policy.mode, .relay)
        XCTAssertEqual(policy.signedRelease?.allowedProfiles, ["locked-read-only"])
        XCTAssertEqual(policy.signedRelease?.minReleaseVersion, "2.3.72")
        XCTAssertEqual(policy.allowedMrtd, [])
    }

    func testAdmissionPolicyFromAnOlderNodeStillDecodes() async throws {
        serve(
            """
            {"data":{"allowedMrtd":["m"],"allowedRtmr0":[],"allowedRtmr1":[],"allowedRtmr2":[],
             "allowedRtmr3":[],"allowedTcbStatuses":[],"acceptMock":true}}
            """)
        let policy = try await admin.getTeeAdmissionPolicy("g-1")
        XCTAssertNil(policy.enabled)
        XCTAssertNil(policy.mode)
        XCTAssertNil(policy.signedRelease)
    }

    // MARK: - Root-guarded owner ops

    func testTransferOwnershipMatchesCoresFixture() async throws {
        let fixture = try Fixture.object("rc83-groups-transfer-ownership-req")
        let req = await capture {
            try await self.admin.transferOwnership(
                "g-1", request: TransferOwnershipRequest(newOwner: "44", rootProof: Self.proof))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/transfer-ownership")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), Set(fixture.keys))
    }

    /// An omitted proof is omitted, never `""` (which the node refuses).
    func testOwnerOpsOmitAnAbsentRootProof() async {
        let req = await capture {
            try await self.admin.transferOwnership("g-1", request: TransferOwnershipRequest(newOwner: "44"))
        }
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["newOwner"])
    }

    func testChangeNamespaceAdminMatchesCoresFixture() async throws {
        let fixture = try Fixture.object("rc83-namespaces-change-admin-req")
        let req = await capture {
            try await self.admin.changeNamespaceAdmin(
                "ns-1", request: ChangeNamespaceAdminRequest(newAdmin: "55", rootProof: Self.proof))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/admin")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), Set(fixture.keys))
    }

    func testOwnerDeleteMatchesCoresFixtureAndDefaultsToAnEmptyObject() async throws {
        let fixture = try Fixture.object("rc83-groups-owner-delete-req")
        var req = await capture {
            try await self.admin.ownerDeleteGroup("g-1", request: RootGuardedOpRequest(rootProof: Self.proof))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/owner-delete")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), Set(fixture.keys))

        req = await capture { try await self.admin.ownerDeleteGroup("g-1") }
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), [])
        XCTAssertNotNil(req.body, "a JSON object is still sent")
    }

    func testTeeAuthoringPolicyPutAndDelete() async {
        var req = await capture {
            try await self.admin.setTeeAuthoringPolicy(
                "ns-1", request: SetTeeAuthoringPolicyRequest(allowedMrtd: ["m"]))
        }
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.path, "/admin-api/groups/ns-1/settings/tee-authoring-policy")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["allowedMrtd"])

        req = await capture { try await self.admin.disableTeeAuthoringPolicy("ns-1") }
        XCTAssertEqual(req.method, "DELETE")
        XCTAssertEqual(req.path, "/admin-api/groups/ns-1/settings/tee-authoring-policy")
        XCTAssertNil(jsonBody(req), "no proof, no body")

        req = await capture {
            try await self.admin.disableTeeAuthoringPolicy(
                "ns-1", request: RootGuardedOpRequest(rootProof: Self.proof))
        }
        XCTAssertEqual(req.method, "DELETE")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["rootProof"])
    }

    /// A stale owner counter is a 409 whose body names the refusal; the
    /// caller re-reads ``GroupInfo/ownerOpCounter`` and re-signs.
    func testAStaleCounterSurfacesItsStatusAndMessage() async {
        serve(#"{"error":"stale owner-op counter: expected 5, got 4"}"#, status: 409)
        do {
            try await admin.transferOwnership("g-1", request: TransferOwnershipRequest(newOwner: "44"))
            XCTFail("expected a refusal")
        } catch let error as MeroError {
            XCTAssertEqual(error.httpStatus, 409)
            XCTAssertEqual(error.refusal?.message, "stale owner-op counter: expected 5, got 4")
            XCTAssertNil(error.refusal?.type)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - GroupInfo / Namespace gained fields

    func testGroupInfoCarriesTheNamespaceAndOwnerCounter() async throws {
        serve(try Fixture.json("rc83-groups-group-info-res"))
        let info = try await admin.getGroupInfo("g-1")
        XCTAssertEqual(info.namespaceId, String(repeating: "d", count: 64))
        XCTAssertEqual(info.ownerOpCounter, 4)
        XCTAssertEqual(info.groupStateHash, String(repeating: "c", count: 64))
    }

    func testGroupInfoFromAnOlderNodeHasNoCounter() async throws {
        serve(try Fixture.json("rc32-group-info"))
        let info = try await admin.getGroupInfo("g-1")
        XCTAssertNil(info.namespaceId)
        XCTAssertNil(info.ownerOpCounter)
    }

    func testNamespaceCarriesFoundingAndHeldOps() async throws {
        serve(try Fixture.json("rc83-namespaces-get-res"))
        let ns = try await admin.getNamespace("ns-1")
        XCTAssertEqual(ns.founding?.founderAccountId, String(repeating: "3", count: 64))
        XCTAssertEqual(ns.founding?.salt, String(repeating: "4", count: 64))
        XCTAssertEqual(ns.heldOps?.ops.first?.deltaId, String(repeating: "5", count: 64))
        XCTAssertEqual(ns.heldOps?.ops.first?.groupId, String(repeating: "6", count: 64))
        XCTAssertEqual(ns.heldOps?.untracked, 0)
    }

    func testNamespaceListingDecodes() async throws {
        serve(try Fixture.json("rc83-namespaces-list-res"))
        let list = try await admin.listNamespaces()
        XCTAssertFalse(list.isEmpty)
    }

    /// A `RelayTee` member must not cost the caller the listing.
    func testMembersListingAcceptsTheRelayTeeRole() async throws {
        serve(try Fixture.json("rc83-groups-members-res"))
        let members = try await admin.listGroupMembers("g-1")
        XCTAssertEqual(members.members.map(\.role), ["Admin", "ReadOnlyTee", "RelayTee"])
    }

    // MARK: - Ownership proofs, typed

    func testNamespaceOwnershipProofCarriesFoundingAndCredential() async throws {
        serve(
            """
            {"signerPublicKey":"aa","signedPayload":"cGF5bG9hZA==","signature":"c2ln",
             "founding":{"founderAccountId":"33","salt":"44"},"credential":"0201"}
            """)
        let proof = try await admin.issueNamespaceOwnershipProof(
            "ns-1",
            request: IssueNamespaceOwnershipProofRequest(
                audience: "https://app", subject: "s", nonce: String(repeating: "0", count: 32), expiresAtMs: 1))
        XCTAssertEqual(proof.founding?.founderAccountId, "33")
        XCTAssertEqual(proof.credential, "0201")
        let req = recorder.requests.last
        XCTAssertEqual(req?.path, "/admin-api/groups/ns-1/issue-namespace-ownership-proof")
        XCTAssertEqual(
            Set((req.flatMap { jsonBody($0) } ?? [:]).keys), ["audience", "subject", "nonce", "expiresAtMs"])
    }

    // MARK: - Context reads and intents

    func testQueryContextSendsMethodAndArgs() async {
        let req = await capture {
            _ = try await self.admin.queryContext(
                "ctx-1", request: QueryContextRequest(method: "get", argsJson: .object(["key": .string("k")])))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/query")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["method", "argsJson"])
    }

    func testQueryContextReturnsTheValue() async throws {
        serve(#"{"data":{"returns":{"value":7}}}"#)
        let data = try await admin.queryContext("ctx-1", request: QueryContextRequest(method: "get"))
        XCTAssertEqual(data.returns, .object(["value": .number(7)]))
    }

    /// A method error from `/query` is a 400 with the JSON-RPC `type`/`data` pair.
    func testQueryMethodErrorSurfacesItsType() async {
        serve(#"{"error":"method failed","type":"FunctionCallError","data":"panicked: nope"}"#, status: 400)
        do {
            _ = try await admin.queryContext("ctx-1", request: QueryContextRequest(method: "get"))
            XCTFail("expected a refusal")
        } catch let error as MeroError {
            XCTAssertEqual(error.httpStatus, 400)
            XCTAssertEqual(error.errorType, "FunctionCallError")
            XCTAssertEqual(error.refusal?.data, .string("panicked: nope"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testIntentRelayCarriesTheWarrantInputs() async throws {
        serve(try Fixture.json("rc83-contexts-intent-relay-res"))
        let info = try await admin.getIntentRelay("ctx-1")
        XCTAssertEqual(recorder.requests.last?.method, "GET")
        XCTAssertEqual(recorder.requests.last?.path, "/admin-api/contexts/ctx-1/intents")
        XCTAssertFalse(info.canAuthorOnBehalf)
        XCTAssertEqual(info.executorKey.count, 64)
        XCTAssertEqual(info.releaseBytecodeId.count, 64)
        XCTAssertEqual(info.releaseVersion, "1.2.0")
        XCTAssertNotNil(info.grantedOnGroupId)
    }

    func testDelegatedIntentRoutes() async {
        var req = await capture {
            try await self.admin.postPresenceIntent(
                "ctx-1",
                request: PresenceIntentRequest(
                    state: nil, seq: 3, sentAtMs: 1_790_000_000_000, signature: "ss", authorProof: "pp"))
        }
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/presence-intents")
        let presence = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(presence.keys), ["state", "seq", "sentAtMs", "signature", "authorProof"])
        XCTAssertTrue(presence["state"] is NSNull, "a retraction sends `state: null`")

        req = await capture { _ = try await self.admin.getContextIntentRelay("g-1", author: "acct") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/context-intents")
        XCTAssertEqual(req.query, "author=acct")

        req = await capture {
            _ = try await self.admin.createContextIntent(
                "g-1", request: CreateContextIntentRequest(warrant: "ww", authorProof: "pp"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["warrant", "authorProof", "initArgs"])

        req = await capture { _ = try await self.admin.getGovernanceIntentRelay("g-1") }
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/governance-intents")

        req = await capture {
            _ = try await self.admin.governanceIntent(
                "g-1", request: GovernanceIntentRequest(warrant: "ww", authorProof: "pp", op: "00"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["warrant", "authorProof", "op"])
    }

    func testDiscoveryResponsesDecode() async throws {
        serve(
            #"{"data":{"executorAccount":"aa","executorKey":"bb","groupId":"g","canCreateOnBehalf":true,"authorMayCreate":false}}"#
        )
        let creation = try await admin.getContextIntentRelay("g", author: "a")
        XCTAssertTrue(creation.canCreateOnBehalf)
        XCTAssertEqual(creation.authorMayCreate, false)

        serve(#"{"data":{"executorAccount":"aa","executorKey":"bb","groupId":"g","canActOnBehalf":false}}"#)
        let governance = try await admin.getGovernanceIntentRelay("g")
        XCTAssertFalse(governance.canActOnBehalf)
    }

    // MARK: - Warrant nonces (not served by rc.83; shape from mero-js)

    func testWarrantNonceRoutes() async {
        var req = await capture { _ = try await self.admin.getWarrantNonce("ctx-1", authorDeviceKey: "dk") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/warrant-nonce/dk")

        req = await capture { _ = try await self.admin.getWarrantNonceAsAuthor("ctx-1", authorProof: "pp") }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/contexts/ctx-1/warrant-nonce")
        XCTAssertEqual(Set((jsonBody(req) ?? [:]).keys), ["authorProof"])
    }

    /// A u64 past 2^53 must come back digit for digit.
    func testWarrantNonceKeepsAU64Exactly() async throws {
        serve(
            """
            {"data":{"contextId":"c","authorDeviceKey":"k","seen":true,
             "highWaterNonce":9007199254740993,"windowWidth":64,"nextNonce":9007199254740994}}
            """)
        let state = try await admin.getWarrantNonce("c", authorDeviceKey: "k")
        XCTAssertEqual(state.nextNonce, 9_007_199_254_740_994)
        XCTAssertEqual(state.highWaterNonce, 9_007_199_254_740_993)
        XCTAssertFalse(state.isExhausted)
    }

    func testAnAbsentNextNonceMeansExhausted() async throws {
        serve(#"{"data":{"contextId":"c","authorDeviceKey":"k","seen":true,"windowWidth":64}}"#)
        let state = try await admin.getWarrantNonce("c", authorDeviceKey: "k")
        XCTAssertTrue(state.isExhausted)
        XCTAssertEqual(state.highWaterNonce, UInt64.max)
    }

    func testAnRc83NodeAnswersTheNonceRouteWith404() async {
        serve("", status: 404)
        do {
            _ = try await admin.getWarrantNonce("c", authorDeviceKey: "k")
            XCTFail("expected a 404")
        } catch let error as MeroError {
            XCTAssertEqual(error.httpStatus, 404)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Account root, devices, sealing

    func testSignWithRootMatchesCoresFixtures() async throws {
        let fixture = try Fixture.object("rc83-account-sign-with-root-req")
        serve(try Fixture.json("rc83-account-sign-with-root-res"))
        let data = try await admin.signWithAccountRoot(
            AccountSignWithRootRequest(domain: AccountSignWithRootRequest.loginDomain, text: "challenge"))
        let req = recorder.requests.last
        XCTAssertEqual(req?.path, "/admin-api/account/sign-with-root")
        let body = req.flatMap { jsonBody($0) } ?? [:]
        XCTAssertEqual(Set(body.keys), Set(fixture.keys))
        XCTAssertEqual(body["payload"] as? String, "6368616c6c656e6765", "UTF-8 of the text, hex")
        XCTAssertEqual(data.rootPublicKey.count, 64)
        XCTAssertTrue(data.signature.hasSuffix("="), "base64, not hex")
    }

    func testLinkDeviceMatchesCoresFixtures() async throws {
        let fixture = try Fixture.object("rc83-namespaces-link-device-req")
        serve(try Fixture.json("rc83-namespaces-link-device-res"))
        let data = try await admin.linkAccountDevice(
            "ns-1", request: LinkAccountDeviceRequest(credential: "02aa", scope: "bb"))
        let req = recorder.requests.last
        XCTAssertEqual(req?.path, "/admin-api/namespaces/ns-1/account/link-device")
        XCTAssertEqual(Set((req.flatMap { jsonBody($0) } ?? [:]).keys), Set(fixture.keys))
        XCTAssertFalse(data.alreadyBound)
        XCTAssertEqual(data.deviceId, String(repeating: "2", count: 64))
    }

    func testSealToAccount() async throws {
        serve(#"{"data":{"accountRootEpoch":2,"ephemeralPublicKey":"ee","nonce":"nn","ciphertext":"cc"}}"#)
        let envelope = try await admin.sealToAccount(
            "g-1", account: "acct", request: SealToAccountRequest(plaintext: "00"))
        XCTAssertEqual(recorder.requests.last?.path, "/admin-api/groups/g-1/accounts/acct/seal")
        XCTAssertEqual(envelope.accountRootEpoch, 2)
        XCTAssertEqual(envelope.ciphertext, "cc")
    }

    func testListGroupMemberDevicesIsTheSameRoute() async {
        let req = await capture { _ = try await self.admin.listGroupMemberDevices("g-1", limit: 5) }
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/member-devices")
        XCTAssertEqual(req.query, "limit=5")
    }

    // MARK: - Delegated execution grants

    func testCanAuthorOnBehalfIsBitNine() {
        XCTAssertEqual(Capabilities.canAuthorOnBehalf, 512)
    }

    /// Read-modify-write: the other default bits survive.
    func testOpenToDelegatedExecutionAddsTheBitAndKeepsTheRest() async throws {
        let recorded = RequestRecorder()
        MockURLProtocol.setHandler { req in
            recorded.append(req)
            let body =
                req.httpMethod == "GET"
                ? Data(try! Fixture.json("rc83-groups-group-info-res").utf8)
                : Data("{}".utf8)
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }
        // The fixture's defaultCapabilities is 0, so the write is exactly the bit.
        let change = try await admin.openToDelegatedExecution("g-1")
        XCTAssertTrue(change.changed)
        XCTAssertEqual(change.capabilities, 512)
        let put = recorded.requests.last
        XCTAssertEqual(put?.method, "PUT")
        XCTAssertEqual(put?.path, "/admin-api/groups/g-1/settings/default-capabilities")
        XCTAssertEqual(put?.jsonBody?["defaultCapabilities"] as? Int, 512)
    }

    func testGrantAuthorshipIsANoOpWhenTheBitIsSet() async throws {
        let recorded = RequestRecorder()
        MockURLProtocol.setHandler { req in
            recorded.append(req)
            return .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"data":{"capabilities":515}}"#.utf8))
        }
        let change = try await admin.grantAuthorship("g-1", account: "acct")
        XCTAssertFalse(change.changed)
        XCTAssertEqual(change.capabilities, 515)
        XCTAssertEqual(recorded.requests.map(\.method), ["GET"], "nothing written")
    }

    // MARK: - Auth

    func testClientKeyCarriesApplicationAndTtl() throws {
        let data = try JSONEncoder().encode(
            GenerateClientKeyRequest(
                contextId: "c", permissions: ["context:execute"], applicationId: "app", ttlSecs: 3600))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["context_id", "permissions", "application_id", "ttl_secs"])
    }

    func testLogoutPostsTheRefreshToken() async {
        let auth = AuthApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession()))
        let req = await capture { _ = try await auth.logout(LogoutRequest(refreshToken: "R")) }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/auth/logout")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["refresh_token"])
        XCTAssertEqual(body["refresh_token"] as? String, "R")
    }

    /// Logout retires the refresh token on the node, then clears locally.
    func testMeroLogoutRetiresTheRefreshTokenThenClears() async throws {
        let node = FakeNode()
        node.install()
        let store = MemoryTokenStore()
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, tokenStore: store),
            session: MockURLProtocol.makeSession())
        let tokens = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
        await mero.logout()
        XCTAssertEqual(node.logoutCalls, 1)
        XCTAssertEqual(node.lastLoggedOutRefreshToken, tokens.refreshToken)
        let authed = await mero.isAuthenticated
        XCTAssertFalse(authed)
        XCTAssertNil(store.getTokens())
    }

    /// A node that cannot retire the token never keeps the caller logged in.
    func testMeroLogoutClearsEvenWhenTheNodeRefuses() async throws {
        let store = MemoryTokenStore()
        store.setTokens(TokenData(accessToken: "A", refreshToken: "R", expiresAt: Date().addingTimeInterval(3600)))
        serve(#"{"error":"Invalid refresh token: expired"}"#, status: 401)
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, tokenStore: store),
            session: MockURLProtocol.makeSession())
        await mero.logout()
        let authed = await mero.isAuthenticated
        XCTAssertFalse(authed)
        XCTAssertNil(store.getTokens())
    }

    // MARK: - JSON-RPC

    func testReadOnlyWriteRefusedIsRecognised() async throws {
        serve(
            """
            {"jsonrpc":"2.0","id":1,"error":{"type":"ReadOnlyWriteRefused","data":{"context_id":"ctx-9"}}}
            """)
        let rpc = RpcClient(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession()))
        do {
            let _: Int = try await rpc.execute(contextId: "ctx-9", method: "set")
            XCTFail("expected a refusal")
        } catch MeroError.rpc(let error) {
            XCTAssertTrue(error.isReadOnlyWriteRefused)
            XCTAssertEqual(error.refusedContextId, "ctx-9")
            XCTAssertTrue(error.message.contains("read-only"), error.message)
        }
    }

    func testExecuteWithMetadataSaysItWentToTheNode() async throws {
        serve(#"{"jsonrpc":"2.0","id":1,"result":{"output":42}}"#)
        let rpc = RpcClient(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession()))
        let result: RpcExecuteResult<Int> = try await rpc.executeWithMetadata(contextId: "c", method: "get")
        XCTAssertEqual(result.returns, 42)
        XCTAssertEqual(result.transport, .node)
    }

    // MARK: - SSE

    /// `groupIds` only when asked for: the params are `deny_unknown_fields`
    /// and an older node does not know the key.
    func testSubscriptionBodyCarriesGroupIdsOnlyWhenAsked() {
        let contextOnly = SseClient.subscriptionBody(sessionId: "s", contextIds: ["c"], groupIds: [])
        XCTAssertEqual(Set((contextOnly["params"] as? [String: Any] ?? [:]).keys), ["contextIds"])

        let both = SseClient.subscriptionBody(sessionId: "s", contextIds: ["c"], groupIds: ["g"])
        let params = both["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(params["groupIds"] as? [String], ["g"])
        XCTAssertEqual(both["method"] as? String, "subscribe")
    }

    /// A group-keyed frame arrives with `groupId`; the stream authenticates in
    /// the header, not the URL; the subscription names the group.
    func testGroupEventsStreamWithTheBearerInTheHeader() async throws {
        let recorded = RequestRecorder()
        let frames =
            "data: {\"type\":\"connect\",\"session_id\":\"s1\"}\n\n"
            + "data: {\"result\":{\"groupId\":\"g1\",\"type\":\"MemberJoined\","
            + "\"data\":{\"memberAccount\":\"aa\"}}}\n\n"
        MockURLProtocol.setHandler { req in
            recorded.append(req)
            if req.url?.path == "/sse" {
                return .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(frames.utf8))
            }
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let client = SseClient(
            baseURL: URL(string: "https://node.test")!, token: { "T" }, session: MockURLProtocol.makeSession())
        var first: ContextEvent?
        for try await event in client.events(contextIds: [], groupIds: ["g1"]) {
            first = event
            break
        }
        XCTAssertEqual(first?.groupId, "g1")
        XCTAssertEqual(first?.kind, "MemberJoined")
        XCTAssertEqual(first?.contextId, "")

        let open = recorded.requests.first { $0.path == "/sse" }
        XCTAssertNil(open?.query, "no `?token=` in the URL")
        XCTAssertEqual(open?.authorization, "Bearer T")
        let subscribe = recorded.requests.first { $0.path == "/sse/subscription" }
        let params = subscribe?.jsonBody?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(params["groupIds"] as? [String], ["g1"])
    }

    /// Presence carried by a relay names the account (core rc.83).
    func testPresenceEventExposesTheAccount() {
        let relayed = ContextEvent(
            contextId: "c", kind: "Ephemeral",
            payload: .object([
                "contextId": .string("c"), "type": .string("Ephemeral"),
                "data": .object(["author": .string("pk"), "account": .string("acct")]),
            ]))
        XCTAssertEqual(relayed.presenceAccount, "acct")
        XCTAssertEqual(relayed.presenceAuthor, "pk")

        let own = ContextEvent(
            contextId: "c", kind: "Ephemeral",
            payload: .object(["data": .object(["author": .string("pk")])]))
        XCTAssertNil(own.presenceAccount, "a node's own presence names no account")
    }
}

extension RequestRecorder {
    /// Record a request from a custom handler (the stock `install()` always answers `{}`).
    func append(_ req: URLRequest) {
        appendCaptured(
            CapturedRequest(
                method: req.httpMethod ?? "GET", path: req.url?.path ?? "", query: req.url?.query,
                body: FakeNode.body(req), authorization: req.value(forHTTPHeaderField: "Authorization")))
    }
}
