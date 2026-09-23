import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// What core moved between 0.11.0-rc.38 and rc.41.
///
/// The short answer is: nothing was taken away. `crates/server/endpoints.json`
/// at rc.38 and at rc.41 differ by two ADDED lines and nothing else, and no
/// request struct closed further — rc.38's `deny_unknown_fields` sweep over 37
/// bodies was the whole of that change, and `Rc38SurfaceTests` still pins it.
///
/// So this file covers the opposite failure to that one. rc.38's risk was a key
/// this SDK still sent; rc.39–rc.41's is a field it silently drops, and a
/// route it does not have. Swift's synthesized `Codable` makes the first
/// invisible by construction — an unknown key is discarded without a word — so
/// the only way a dropped field shows up is a test that decodes the node's own
/// bytes and asserts the field arrived.
///
/// The response fixtures below are the wire fixtures core ships in
/// `crates/server/primitives/fixtures/wire/`, copied verbatim, so the bytes
/// asserted here are the bytes core's own suite asserts it writes.
final class Rc41SurfaceTests: XCTestCase {
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

    /// Serve one fixed body to every request, for the decode half of the file.
    private func serve(_ json: String) {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(json.utf8))
        }
    }

    // MARK: - PUT /account/devices/{id}/scope  (new in rc.41)

    /// `"all"` is a bare string, not `{"all": ...}` and not `[]`.
    ///
    /// The shape matters more than it looks: core made this a tagged enum
    /// precisely so an empty list could not be mistaken for "everything", and
    /// it refuses an `only` naming nothing with a `400` rather than widening
    /// the device. Encoding `.all` as anything else would ask for a scope the
    /// caller did not choose.
    func testRescopeDeviceSendsAllAsABareTag() async {
        let req = await capture {
            _ = try await self.admin.rescopeDevice("dev-1", request: RescopeDeviceRequest(scope: .all))
        }
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.path, "/admin-api/account/devices/dev-1/scope")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["scope"], "the body is `deny_unknown_fields`")
        XCTAssertEqual(body["scope"] as? String, "all")
    }

    func testRescopeDeviceSendsOnlyAsATaggedObject() async {
        let apps = [String(repeating: "11", count: 32), String(repeating: "22", count: 32)]
        let req = await capture {
            _ = try await self.admin.rescopeDevice(
                "dev-1", request: RescopeDeviceRequest(scope: .only(apps)))
        }
        XCTAssertEqual(req.method, "PUT")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["scope"])
        let scope = body["scope"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(scope.keys), ["only"])
        XCTAssertEqual(scope["only"] as? [String], apps)
    }

    /// A round trip through the wire shape, which is the half a request-only
    /// assertion cannot reach: the response carries the scope back.
    func testDeviceScopeRoundTripsThroughJson() throws {
        for scope in [DeviceScope.all, .only(["aa", "bb"])] {
            let data = try JSONEncoder().encode(RescopeDeviceRequest(scope: scope))
            let decoded = try JSONDecoder().decode(RescopeDeviceRequest.self, from: data)
            XCTAssertEqual(decoded.scope, scope)
        }
    }

    /// `descoped` is the field that says whether a narrowing actually took
    /// effect: `keyRotated: false` means the device stopped writing there but
    /// still HOLDS the key it had, until an admin rotates. Dropping it would
    /// report a half-finished revocation as a finished one.
    func testRescopeResponseCarriesDescopedAndItsRotationFlag() async throws {
        serve(
            """
            {"data":{"accountId":"aa","deviceId":"dd","applications":["app-1"],
             "descoped":[{"namespaceId":"ns-1","keyRotated":false}],
             "linkedIn":[{"namespaceId":"ns-2","keyDelivered":true}],
             "skipped":[{"namespaceId":"ns-3","reason":"not a member"}]}}
            """)
        let data = try await admin.rescopeDevice(
            "dev-1", request: RescopeDeviceRequest(scope: .only(["app-1"])))
        XCTAssertEqual(data.applications, ["app-1"])
        XCTAssertEqual(data.descoped.count, 1)
        XCTAssertEqual(data.descoped.first?.namespaceId, "ns-1")
        XCTAssertEqual(
            data.descoped.first?.keyRotated, false,
            "the device still holds the key it had; the narrowing is not complete")
        XCTAssertEqual(data.linkedIn.first?.keyDelivered, true)
        XCTAssertEqual(data.skipped.first?.reason, "not a member")
    }

    // MARK: - PUT /account/devices/{id}/label  (new in rc.41)

    func testLabelDeviceSendsExactlyTheLabel() async {
        let req = await capture {
            _ = try await self.admin.labelDevice(
                "dev-1", request: LabelDeviceRequest(label: "Work laptop"))
        }
        XCTAssertEqual(req.method, "PUT")
        XCTAssertEqual(req.path, "/admin-api/account/devices/dev-1/label")
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["label"], "the body is `deny_unknown_fields`")
        XCTAssertEqual(body["label"] as? String, "Work laptop")
    }

    func testLabelResponseCarriesTheEpoch() async throws {
        serve(#"{"data":{"accountId":"aa","deviceId":"dd","label":"Work laptop","labelEpoch":3}}"#)
        let data = try await admin.labelDevice("dev-1", request: LabelDeviceRequest(label: "Work laptop"))
        XCTAssertEqual(data.label, "Work laptop")
        XCTAssertEqual(
            data.labelEpoch, 3,
            "orders this rename against one another device of the account made at the same time")
    }

    // MARK: - GET /account/devices gained `label`

    /// Verbatim from core's `fixtures/wire/account/devices.res.json`.
    ///
    /// Note the second entry: `label` is SKIPPED, not null, for a device with
    /// no name — so "no name" and "this node predates the field" are the same
    /// bytes, and both have to decode.
    func testDeviceListingCarriesTheLabelAndSurvivesItsAbsence() async throws {
        serve(
            """
            {"devices":[
              {"applications":[],"deviceId":"2222222222222222222222222222222222222222222222222222222222222222",
               "isSelf":true,"label":"Work laptop",
               "namespaces":["7777777777777777777777777777777777777777777777777777777777777777"],
               "revoked":false,"signingKey":"3333333333333333333333333333333333333333333333333333333333333333"},
              {"applications":["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
               "deviceId":"9999999999999999999999999999999999999999999999999999999999999999",
               "isSelf":false,"namespaces":[],"revoked":true,
               "signingKey":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
            ]}
            """)
        let devices = try await admin.listAccountDevices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].label, "Work laptop")
        XCTAssertNil(devices[1].label, "an unnamed device omits the key rather than sending null")
    }

    // MARK: - GET /contexts/{id}/identities-owned gained `identitiesOf`

    /// Verbatim from core's `fixtures/wire/contexts/identities.res.json`.
    ///
    /// The listing answers a different question depending on who asks — the
    /// node's own signing identities for a node-owner session, the calling
    /// account's certified devices for a delegated one. Before rc.41 a caller
    /// had to infer which from its own token; dropping the field puts it back
    /// to guessing.
    func testContextIdentitiesCarryWhoseTheyAre() async throws {
        serve(
            """
            {"data":{"identities":[
              "d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
              "d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"
            ],"identitiesOf":"caller"}}
            """)
        let data = try await admin.getContextIdentitiesOwned("ctx-1")
        XCTAssertEqual(data.identities.count, 2)
        XCTAssertEqual(data.identitiesOf, .caller)
    }

    /// A node predating the field said nothing about it, and absent is the
    /// honest reading — not a guess at a variant, which could be wrong in the
    /// direction that matters.
    func testContextIdentitiesWithoutTheFieldDecodeToNil() async throws {
        serve(#"{"data":{"identities":["d1"]}}"#)
        let data = try await admin.getContextIdentities("ctx-1")
        XCTAssertEqual(data.identities, ["d1"])
        XCTAssertNil(data.identitiesOf)
    }

    /// A variant this SDK does not know yet must not cost the caller the
    /// identities. The synthesized decoder would throw the whole response away
    /// to complain about a label.
    func testAnUnknownIdentitiesOfDoesNotFailTheWholeResponse() async throws {
        serve(#"{"data":{"identities":["d1","d2"],"identitiesOf":"somethingNewer"}}"#)
        let data = try await admin.getContextIdentities("ctx-1")
        XCTAssertEqual(data.identities, ["d1", "d2"], "a listing is still a listing")
        XCTAssertNil(data.identitiesOf)
    }

    // MARK: - GET /identity gained `revokedFrom` (and had been dropping `accountNamespaceId`)

    /// Verbatim from core's `fixtures/wire/identity/node_identity.res.json`.
    ///
    /// `accountNamespaceId` is not an rc.41 addition — it has been on the wire
    /// since before rc.38 and this SDK simply never read it, which left
    /// ``AccountPairInitRequest/accountNamespace`` with nothing to fill it
    /// from. It is asserted here because this is the first test that decodes
    /// the node's own bytes for this response.
    func testNodeIdentityKeepsTheAccountNamespaceAndReportsNoRevocation() async throws {
        serve(
            """
            {"data":{
              "accountId":"1111111111111111111111111111111111111111111111111111111111111111",
              "accountNamespaceId":"6666666666666666666666666666666666666666666666666666666666666666",
              "accountRootPublicKey":"4444444444444444444444444444444444444444444444444444444444444444",
              "deviceAgreementKey":"5555555555555555555555555555555555555555555555555555555555555555",
              "deviceCertified":true,
              "deviceId":"2222222222222222222222222222222222222222222222222222222222222222",
              "holdsAccountRoot":true,
              "publicKey":"3333333333333333333333333333333333333333333333333333333333333333"}}
            """)
        let identity = try await admin.getNodeIdentity()
        XCTAssertEqual(
            identity.accountNamespaceId, String(repeating: "66", count: 32),
            "the id `accountNamespace` on a pair-init has to come from somewhere")
        XCTAssertTrue(identity.holdsAccountRoot)
        XCTAssertNil(
            identity.revokedFrom,
            "skipped rather than null, so a node no revocation has reached answers as it did")
    }

    /// A device whose account withdrew it is not a login problem, and the only
    /// thing on the wire that says so is this field.
    func testNodeIdentityReportsWhoRevokedIt() async throws {
        serve(
            """
            {"data":{"accountId":"aa","publicKey":"bb","accountRootPublicKey":"cc",
             "revokedFrom":{"accountId":"4444444444444444444444444444444444444444444444444444444444444444",
                            "deviceId":"5555555555555555555555555555555555555555555555555555555555555555"}}}
            """)
        let identity = try await admin.getNodeIdentity()
        XCTAssertEqual(identity.revokedFrom?.deviceId, String(repeating: "55", count: 32))
        XCTAssertEqual(identity.revokedFrom?.accountId, String(repeating: "44", count: 32))
    }

    // MARK: - Blob discovery is context-scoped or it is nothing  (rc.39/rc.41)

    /// core 0.11.0-rc.39 removed blob discovery from the DHT. Naming the
    /// context is now the ONLY way to reach a blob a peer holds, so a call
    /// without one sees the local store and nothing else — and answers 404 for
    /// a blob that plainly exists on the node next to it.
    func testGetBlobNamesTheContextWhenGivenOne() async {
        let req = await capture { _ = try await self.admin.getBlob("blob-1", contextId: "ctx-1") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/admin-api/blobs/blob-1")
        XCTAssertEqual(req.query, "context_id=ctx-1", "snake_case, as `uploadBlob` spells it")
    }

    /// And stays exactly the call it was when no context is named, so a local
    /// fetch does not start paying for a probe sweep.
    func testGetBlobWithoutAContextSendsNoQuery() async {
        let req = await capture { _ = try await self.admin.getBlob("blob-1") }
        XCTAssertNil(req.query)
    }

    func testGetBlobInfoNamesTheContextWhenGivenOne() async {
        let req = await capture { _ = try await self.admin.getBlobInfo("blob-1", contextId: "ctx-1") }
        XCTAssertEqual(req.method, "HEAD")
        XCTAssertEqual(req.path, "/admin-api/blobs/blob-1")
        XCTAssertEqual(req.query, "context_id=ctx-1")
    }

    /// The whole point of `X-Blob-Source`: a `peer` answer omits every header
    /// derived from bytes this node does not hold, and without the source
    /// header a missing `X-Blob-Hash` is indistinguishable from a bug.
    func testBlobInfoReportsAPeerAnswerAsSuch() async throws {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200,
                headers: [
                    "X-Blob-ID": "blob-1", "Content-Length": "1024", "X-Blob-Source": "peer",
                ],
                body: Data())
        }
        let info = try await admin.getBlobInfo("blob-1", contextId: "ctx-1")
        XCTAssertEqual(info.source, .peer)
        XCTAssertEqual(info.size, 1024, "the holder's word, verified by nobody")
        XCTAssertNil(info.hash, "computed from bytes this node does not have")
        XCTAssertNil(info.mimeType, "sniffed from a first chunk this node does not have")
    }

    /// A local answer is what it always was, plus the label.
    func testBlobInfoReportsALocalAnswerAsSuch() async throws {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200,
                headers: [
                    "X-Blob-ID": "blob-1", "Content-Length": "7", "X-Blob-Source": "local",
                    "X-Blob-Hash": "abcd", "X-Blob-MIME-Type": "image/png",
                ],
                body: Data())
        }
        let info = try await admin.getBlobInfo("blob-1")
        XCTAssertEqual(info.source, .local)
        XCTAssertEqual(info.size, 7)
        XCTAssertEqual(info.hash, "abcd")
        XCTAssertEqual(info.mimeType, "image/png")
    }

    /// `Content-Length` is OMITTED when a peer reported no size — "it exists,
    /// size unknown", which is true, where `0` would be a lie about a blob
    /// that exists. A caller testing `size > 0` would read present as absent.
    func testABlobOfUnknownSizeIsNilAndNotZero() async throws {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: ["X-Blob-ID": "blob-1", "X-Blob-Source": "peer"],
                body: Data())
        }
        let info = try await admin.getBlobInfo("blob-1", contextId: "ctx-1")
        XCTAssertNil(info.size)
        XCTAssertEqual(info.source, .peer)
    }

    /// A node predating `X-Blob-Source` answers from its own store and says
    /// nothing about it. `nil` is the reading; `.local` would be a guess.
    func testBlobInfoFromAnOlderNodeHasNoSource() async throws {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: ["X-Blob-ID": "blob-1", "Content-Length": "7"], body: Data())
        }
        let info = try await admin.getBlobInfo("blob-1")
        XCTAssertNil(info.source)
        XCTAssertEqual(info.size, 7)
    }

    // MARK: - pair-init: the optional key must stay optional

    /// `accountNamespace` is new to this SDK, not to core, and the body is
    /// `deny_unknown_fields` — so the one thing that would be fatal is sending
    /// the key as `null` when the caller named nothing. It has to be absent.
    func testPairInitOmitsTheAccountNamespaceWhenUnset() async {
        let req = await capture {
            _ = try await self.admin.accountPairInit(
                AccountPairInitRequest(accountRootPublicKey: "root", namespaces: ["ns-1"]))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(Set(body.keys), ["accountRootPublicKey", "namespaces"])
    }

    /// And when it IS named, an empty namespace set is legal — that pairing is
    /// exactly what the field exists for, and core refuses only the request
    /// that names neither.
    func testPairInitCanCarryTheAccountNamespaceAlone() async {
        let req = await capture {
            _ = try await self.admin.accountPairInit(
                AccountPairInitRequest(
                    accountRootPublicKey: "root", namespaces: [],
                    accountNamespace: String(repeating: "66", count: 32)))
        }
        let body = jsonBody(req) ?? [:]
        XCTAssertEqual(
            Set(body.keys), ["accountRootPublicKey", "namespaces", "accountNamespace"])
        XCTAssertEqual(body["accountNamespace"] as? String, String(repeating: "66", count: 32))
    }
}
