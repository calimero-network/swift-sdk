import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// What core moved between 0.11.0-rc.29 and rc.32, plus the alias family this
/// bump found broken along the way.
///
/// Same two halves as `Rc29SurfaceTests`: the **request** half pins verb, path
/// and body keys; the **response** half decodes bodies captured verbatim from a
/// live rc.32 node. rc.32's changes are exactly the kind a request-only suite
/// cannot see — a renamed envelope field (`admitter_hints` → `admitter_addrs`),
/// an added response field (`holdsAccountRoot`), and a request whose old shape
/// core now refuses outright (`install-application`).
final class Rc32SurfaceTests: XCTestCase {
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

    private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Fixture.decode(type, name)
    }

    // MARK: - Install by coordinates  (core#3652, "registry-only distribution")

    /// The break itself: the body carries coordinates and nothing else.
    ///
    /// core declares the request `deny_unknown_fields`, so this is not a field
    /// the SDK may keep sending for compatibility — a `url` key turns a working
    /// install into a 400.
    func testInstallApplicationSendsCoordinatesOnly() async {
        let req = await capture {
            _ = try await self.admin.installApplication(
                InstallApplicationRequest(package: "com.calimero.chat", version: "3.1.1"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/install-application")
        let body = try? XCTUnwrap(jsonBody(req))
        XCTAssertEqual(body?["package"] as? String, "com.calimero.chat")
        XCTAssertEqual(body?["version"] as? String, "3.1.1")
        XCTAssertEqual(
            Set((body ?? [:]).keys), ["package", "version"],
            "any extra key makes an rc.32 node refuse the whole request")
    }

    /// `installFromRegistry` used to fetch a bundle manifest off-node, derive an
    /// artifact URL and post that. It must now be the one node request.
    func testInstallFromRegistryIsOneNodeRequest() async {
        let req = await capture {
            _ = try await self.admin.installFromRegistry(
                packageName: "com.calimero.kv-store", version: "0.1.0")
        }
        XCTAssertEqual(req.path, "/admin-api/install-application")
        let body = jsonBody(req)
        XCTAssertEqual(body?["package"] as? String, "com.calimero.kv-store")
        XCTAssertEqual(body?["version"] as? String, "0.1.0")
    }

    func testInstallApplicationDecodesALiveNodeResponse() throws {
        let wrapper = try fixture(
            ApiResponse<InstallApplicationResponseData>.self, "rc32-install-application")
        XCTAssertEqual(try XCTUnwrap(wrapper.data).applicationId.count, 64)
    }

    /// What a stale client gets, captured from the live node: not a silent
    /// install of something else, and not a 500.
    ///
    /// The 502 for unpublished coordinates has no JSON body at all — it answers
    /// `the configured Http source has no application published at <pkg>@<ver>`
    /// as plain text, which surfaces through `MeroError.http`.
    func testAUrlShapedInstallBodyIsRefusedByTheNode() throws {
        let wrapper = try fixture(
            ApiResponse<InstallApplicationResponseData>.self, "rc32-install-application-url-refused")
        XCTAssertNil(wrapper.data)
        let error = try XCTUnwrap(wrapper.error)
        XCTAssertTrue(
            error.contains("unknown field `url`"),
            "an rc.32 node names the offending field: \(error)")
    }

    /// rc.32 reduced the dev-install body to the path. Unlike the coordinate
    /// install this one is not `deny_unknown_fields`, so the old fields would
    /// have been accepted and ignored — silence being the reason to check.
    func testInstallDevApplicationSendsPathOnly() async {
        let req = await capture {
            _ = try await self.admin.installDevApplication(
                InstallDevApplicationRequest(path: "/tmp/app.mpk"))
        }
        XCTAssertEqual(req.path, "/admin-api/install-dev-application")
        let body = try? XCTUnwrap(jsonBody(req))
        XCTAssertEqual(body?["path"] as? String, "/tmp/app.mpk")
        XCTAssertEqual(Set((body ?? [:]).keys), ["path"])
    }

    // MARK: - Node identity gained `holdsAccountRoot`  (core#3774)

    func testNodeIdentityCarriesHoldsAccountRoot() throws {
        let wrapper = try fixture(ApiResponse<NodeIdentity>.self, "rc32-node-identity")
        let identity = try XCTUnwrap(wrapper.data)
        XCTAssertTrue(identity.holdsAccountRoot)
        // Still the mapping this route exists for: both ids are 64 hex since
        // rc.27, so only provenance separates an account from a device.
        XCTAssertEqual(identity.accountId.count, 64)
        XCTAssertEqual(identity.deviceId?.count, 64)
        XCTAssertNotEqual(identity.accountId, identity.deviceId)
    }

    /// A node predating the field must still decode, rather than failing the
    /// whole response — which is why the field is defaulted and not optional.
    func testNodeIdentityFromAPreRc32NodeDefaultsToNotHoldingTheRoot() throws {
        let wrapper = try fixture(ApiResponse<NodeIdentity>.self, "rc29-node-identity")
        let identity = try XCTUnwrap(wrapper.data)
        XCTAssertFalse(identity.holdsAccountRoot)
        XCTAssertEqual(identity.accountId.count, 64)
    }

    // MARK: - Invitations: `admitter_hints` → `admitter_addrs`  (core#3819/#3770)

    /// The envelope field core renamed *and* reshaped: a tagged
    /// `{"multiaddr": …}` / `{"url": …}` enum became a plain multiaddr string.
    func testInvitationEnvelopeCarriesAdmitterAddrs() throws {
        let wrapper = try fixture(
            ApiResponse<CreateNamespaceInvitationResponseData>.self, "rc32-namespace-invitation")
        let envelope = try XCTUnwrap(wrapper.data).invitation
        let addr = try XCTUnwrap(envelope.admitterAddrs.first)
        XCTAssertTrue(addr.hasPrefix("/ip4/"), "a full multiaddr: \(addr)")
        XCTAssertTrue(
            addr.contains("/p2p/"),
            "the peer id travels with the address; a joiner cannot resolve one")
        // Still signed, still an account: authority comes from this list, and
        // the address above is only where to knock.
        XCTAssertEqual(envelope.invitation.admitters.count, 1)
        XCTAssertEqual(try XCTUnwrap(envelope.invitation.admitters.first).count, 64)
    }

    /// The old key must not be read as the new field: an rc.32 node does not
    /// send `admitter_hints`, so a value found there is not an address list.
    func testAnAdmitterHintsKeyIsNotReadAsAnAddress() throws {
        let json = """
            {"invitation":{"inviter_identity":[1],"group_id":[2],"expiration_timestamp":3,
             "secret_salt":[4],"admitters":["ab"]},"inviter_signature":"sig",
             "admitter_hints":[{"multiaddr":"/ip4/10.0.0.1/tcp/2528/p2p/12D3KooW"}]}
            """
        let envelope = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: Data(json.utf8))
        XCTAssertTrue(envelope.admitterAddrs.isEmpty)
        // Not dropped either — an unnamed key rides `passthrough` verbatim, so a
        // round-trip cannot invalidate the signature over the inner body.
        XCTAssertNotNil(envelope.passthrough["admitter_hints"])
        let reencoded =
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(envelope)) as? [String: Any]
        XCTAssertNotNil(reencoded?["admitter_hints"])
    }

    /// A full round-trip of the live envelope has to come back byte-identical in
    /// key set: the node re-encodes this to borsh and checks the signature.
    func testLiveInvitationRoundTripsWithoutLosingAKey() throws {
        let raw = try Fixture.object("rc32-namespace-invitation")
        let wrapper = try fixture(
            ApiResponse<CreateNamespaceInvitationResponseData>.self, "rc32-namespace-invitation")
        let envelope = try XCTUnwrap(wrapper.data).invitation
        let reencoded =
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(envelope)) as? [String: Any]

        let original = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: try JSONEncoder().encode(raw))
                as? [String: Any])?["data"] as? [String: Any])
        let originalEnvelope = try XCTUnwrap(original["invitation"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(reencoded).keys), Set(originalEnvelope.keys),
            "a dropped envelope key is a refused join")
        let originalBody = try XCTUnwrap(originalEnvelope["invitation"] as? [String: Any])
        let bodyBack = try XCTUnwrap(reencoded?["invitation"] as? [String: Any])
        XCTAssertEqual(Set(bodyBack.keys), Set(originalBody.keys))
    }

    /// Requesting side: rc.32 added `admitterAddrs`, used as given rather than
    /// merged with what the node has on file.
    func testInvitationRequestsSendAdmitterAddrs() async {
        let addr = "/ip4/10.0.0.7/tcp/4102/p2p/12D3KooWCdWRrkvjmXn1uQjodhfioKaGQtpBTR7Txxs"
        var req = await capture {
            _ = try await self.admin.createNamespaceInvitation(
                "ns-1",
                request: CreateNamespaceInvitationRequest(
                    admitters: ["ab"], admitterAddrs: [addr]))
        }
        XCTAssertEqual(req.path, "/admin-api/namespaces/ns-1/invite")
        XCTAssertEqual(jsonBody(req)?["admitterAddrs"] as? [String], [addr])

        req = await capture {
            _ = try await self.admin.createGroupInvitation(
                "g-1", request: CreateGroupInvitationRequest(admitterAddrs: [addr]))
        }
        XCTAssertEqual(req.path, "/admin-api/groups/g-1/invite")
        XCTAssertEqual(jsonBody(req)?["admitterAddrs"] as? [String], [addr])
    }

    /// Absent rather than `[]` when empty: core skips the field when empty, and
    /// a node older than rc.32 has no such field to read.
    func testAnEmptyAdmitterAddrsIsOmitted() async {
        let req = await capture {
            _ = try await self.admin.createNamespaceInvitation(
                "ns-1", request: CreateNamespaceInvitationRequest())
        }
        XCTAssertNil(jsonBody(req)?["admitterAddrs"])
    }

    // MARK: - Aliases: a map, a null payload, and a family that never existed

    /// core answers a listing as a map keyed by alias name. The SDK modelled
    /// `{"aliases": [...]}`, so every listing threw — the empty one included,
    /// which is why no fixture-free test noticed.
    func testAliasListingDecodesTheMapCoreActuallySends() throws {
        let wrapper = try fixture(ApiResponse<ListAliasesResponseData>.self, "rc32-alias-list-device")
        let data = try XCTUnwrap(wrapper.data)
        XCTAssertEqual(data.entries.count, 1)
        let entry = try XCTUnwrap(data.aliases.first)
        XCTAssertEqual(entry.name, "laptop")
        XCTAssertEqual(entry.value.count, 64)
    }

    func testAnEmptyAliasListingIsNotAnError() throws {
        let wrapper = try JSONDecoder().decode(
            ApiResponse<ListAliasesResponseData>.self, from: Data(#"{"data":{}}"#.utf8))
        XCTAssertTrue(try XCTUnwrap(wrapper.data).aliases.isEmpty)
    }

    /// The alias mutations answer `{"data": null}`. Unwrapping that as a missing
    /// payload turned every successful create and delete into a thrown error.
    func testAliasMutationsSucceedOnANullPayload() async throws {
        // The captured body verbatim: `{"data": null}`.
        let nullPayload = try Fixture.data("rc32-alias-create")
        MockURLProtocol.setHandler { _ in
            .init(status: 200, headers: ["Content-Type": "application/json"], body: nullPayload)
        }
        let api = AdminApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!,
                session: MockURLProtocol.makeSession()))
        _ = try await api.createDeviceAlias(
            CreateDeviceAliasRequest(alias: "laptop", deviceId: String(repeating: "a", count: 64)))
        _ = try await api.deleteDeviceAlias("laptop")
        _ = try await api.createContextAlias(
            CreateContextAliasRequest(alias: "main", contextId: "ctx-1"))
        _ = try await api.deleteApplicationAlias("chat")
    }

    /// The device alias family, which replaces the "context identity alias" one
    /// that called `/alias/*/identity/...` — routes a live rc.32 node answers
    /// with 404, and that no released node ever served.
    func testDeviceAliasRequests() async {
        var req = await capture {
            _ = try await self.admin.createDeviceAlias(
                CreateDeviceAliasRequest(alias: "laptop", deviceId: "ab"))
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/alias/create/device")
        // Note the key: core reads `deviceId`, not `identity` or `value`.
        XCTAssertEqual(jsonBody(req)?["deviceId"] as? String, "ab")

        req = await capture { _ = try await self.admin.lookupDeviceAlias("laptop") }
        XCTAssertEqual(req.path, "/admin-api/alias/lookup/device/laptop")

        req = await capture { _ = try await self.admin.deleteDeviceAlias("laptop") }
        XCTAssertEqual(req.path, "/admin-api/alias/delete/device/laptop")

        req = await capture { _ = try await self.admin.listDeviceAliases() }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/alias/list/device")
    }

    // MARK: - axum 0.8 stopped matching a trailing slash  (core rc.31)

    /// `syncContext(nil)` means "sync everything", and used to interpolate an
    /// empty id into the per-context path — `/contexts/sync/`. core moved to
    /// axum 0.8 in rc.31, which no longer matches that against `/contexts/sync`:
    /// a live rc.32 node answers 404 and syncs nothing.
    func testSyncEverythingHasNoTrailingSlash() async {
        var req = await capture { try await self.admin.syncContext() }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/admin-api/contexts/sync")

        req = await capture { try await self.admin.syncContext("c1") }
        XCTAssertEqual(req.path, "/admin-api/contexts/sync/c1")
    }

    // MARK: - Fields core sends that the SDK was dropping

    /// `upgradePolicy` is gone from a namespace and `appVersion` took its place:
    /// a policy nobody applied, replaced by the version actually in force. It is
    /// what an Updates flow compares against the registry.
    func testNamespaceCarriesAppVersionAndNoUpgradePolicy() throws {
        let wrapper = try fixture(ApiResponse<ListNamespacesResponseData>.self, "rc32-namespaces")
        let namespace = try XCTUnwrap(try XCTUnwrap(wrapper.data).first)
        XCTAssertEqual(namespace.appVersion, "3.1.1")
        XCTAssertNil(namespace.upgradePolicy, "rc.32 does not send it")
        // Optional, not required: a node predating the field must still decode.
        let older = try JSONDecoder().decode(
            Namespace.self,
            from: Data(
                #"{"namespaceId":"a","appKey":"b","targetApplicationId":"c","createdAt":1,"#
                    .appending(#""memberCount":1,"contextCount":0,"subgroupCount":0}"#).utf8))
        XCTAssertNil(older.appVersion)
    }

    /// The group-level member of core's three-level state-hash naming (context /
    /// group / namespace): agreement here is agreement on membership, roles and
    /// capabilities.
    func testGroupInfoCarriesGroupStateHash() throws {
        let wrapper = try fixture(ApiResponse<GroupInfo>.self, "rc32-group-info")
        let info = try XCTUnwrap(wrapper.data)
        XCTAssertEqual(try XCTUnwrap(info.groupStateHash).count, 64)
        XCTAssertNil(info.upgradePolicy, "rc.32 does not send it")
        XCTAssertEqual(info.subgroupVisibility, "restricted")
    }

    // MARK: - SSE frames say `StateMutation`, never `ExecutionEvent`

    /// The discriminator is `result.type`, and a node sends `StateMutation` or
    /// `SyncStatus`. The SDK's own docs told callers to switch on an
    /// `ExecutionEvent` that no node has ever sent, so the branch never fired.
    ///
    /// The frame below is verbatim from a live 0.11.0-rc.32 node, produced by a
    /// `set` on a kv-store context.
    func testSseFrameIsAStateMutationCarryingNestedContractEvents() throws {
        let frame = try Fixture.object("rc32-sse-state-mutation")
        let result = try XCTUnwrap(frame["result"]?.objectValue)
        XCTAssertEqual(result["type"]?.stringValue, "StateMutation")
        XCTAssertNotEqual(result["type"]?.stringValue, "ExecutionEvent")
        XCTAssertEqual(try XCTUnwrap(result["contextId"]?.stringValue).count, 64)

        // The contract's own events sit a level down, each with its own `kind`.
        let data = try XCTUnwrap(result["data"]?.objectValue)
        XCTAssertEqual(try XCTUnwrap(data["newRoot"]?.stringValue).count, 64)
        let events = try XCTUnwrap(data["events"]?.arrayValue)
        let first = try XCTUnwrap(events.first?.objectValue)
        XCTAssertEqual(first["kind"]?.stringValue, "Inserted")
        XCTAssertFalse(
            try XCTUnwrap(first["data"]?.arrayValue).isEmpty,
            "the encoded contract event, as a byte array")
    }

    // MARK: - The flat-envelope quirks, re-verified at rc.32

    /// Three routes answer their payload flat rather than under `data`. Nothing
    /// in rc.30–rc.32 changed that, and a bump is when it would have.
    func testTheFlatResponsesAreStillFlatAtRc32() throws {
        let devices = try fixture(AccountDevicesResponse.self, "rc32-account-devices")
        XCTAssertTrue(try XCTUnwrap(devices.devices.first).isSelf)
        let applications = try fixture(AccountApplicationsResponse.self, "rc32-account-applications")
        XCTAssertEqual(try XCTUnwrap(applications.applications.first).applicationId.count, 64)
        let members = try fixture(ListMemberDevicesResponseData.self, "rc32-member-devices")
        let member = try XCTUnwrap(members.members.first)
        XCTAssertNotEqual(member.account, try XCTUnwrap(member.devices.first).deviceId)
    }
}
