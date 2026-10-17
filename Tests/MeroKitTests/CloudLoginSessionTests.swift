import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Every session a ``CloudClient`` reported through `onSession`.
final class CloudSessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String?] = []

    func record(_ session: CloudLoginSession?) {
        lock.lock()
        tokens.append(session?.sessionToken)
        lock.unlock()
    }

    var seen: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }
}

/// Port of mero-js `cloud-client.test.ts` (sign-in, relays, namespaces,
/// machines, HA, linking) and `account-login.test.ts`.
final class CloudLoginSessionTests: XCTestCase {
    private var rig: CloudRig!
    private let base = URL(string: "https://cloud.example")!
    private let ns = String(repeating: "01", count: 32)
    private let executor = String(repeating: "4d", count: 32)
    private let sessionBody =
        #"{"session_token":"session-1","expires_at":1800000000,"#
        + #""user":{"email":"someone@example.com","name":"Someone"}}"#

    override func setUp() {
        super.setUp()
        rig = CloudRig()
        rig.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        rig = nil
        super.tearDown()
    }

    private func client(
        token: String? = nil, store: AnyValueStore<CloudLoginSession>? = nil, log: CloudSessionLog? = nil
    ) -> CloudClient {
        var onSession: (@Sendable (CloudLoginSession?) -> Void)?
        if let log { onSession = { log.record($0) } }
        return CloudClient(
            baseURL: base, sessionToken: token, sessionStore: store, onSession: onSession,
            session: MockURLProtocol.makeSession())
    }

    /// A relay row as the cloud sends it, with `over` replacing its fields.
    private func relayRow(_ over: [String: JSONValue] = [:]) -> JSONValue {
        var row: [String: JSONValue] = [
            "peer_id": "12D3KooWpeer", "relay_url": "https://relay.example", "executor_account": .string(executor),
            "status": "active", "authorship_ready": true, "tee_role": "RelayTee", "can_execute": true,
            "last_seen_at": "2026-01-01T00:00:00", "confirmed_at": "2026-01-01T00:00:00",
        ]
        row.merge(over) { _, new in new }
        return .object(row)
    }

    /// A row from a cloud that predates `can_execute` and `tee_role`.
    private func legacyRow(_ over: [String: JSONValue] = [:]) -> JSONValue {
        var row = relayRow(over).objectValue ?? [:]
        row.removeValue(forKey: "can_execute")
        row.removeValue(forKey: "tee_role")
        return .object(row)
    }

    /// Serve `rows` as the namespace's relays.
    private func serveRelays(_ rows: [JSONValue]) {
        let body = String(decoding: CanonicalJSON.data(["relays": .array(rows)]), as: UTF8.self)
        rig.on("GET", "/api/cloud/me/namespaces/\(ns)/relays", json: body)
    }

    /// Whether `signature` (standard base64) is the root's over `domain ‖ nonce`.
    private func rootSigned(_ signature: String, by publicKey: String, domain: String, nonce: String) throws -> Bool {
        Ed25519.verify(
            publicKey: try Hex.decode(publicKey, label: "pk", bytes: 32),
            signature: try XCTUnwrap(Data(base64Encoded: signature)), message: Data((domain + nonce).utf8))
    }

    // MARK: - Sign-in

    func testDefaultsToTheManagerAPI() async throws {
        rig.on("POST", "/api/auth/google", json: sessionBody)
        _ = try await CloudClient(session: MockURLProtocol.makeSession()).signInWithGoogle("google-id-token")
        XCTAssertEqual(rig.seen.first?.url.host, "manager.cloud.calimero.network")
    }

    func testExchangesAGoogleIdTokenForASessionAndKeepsIt() async throws {
        rig.on("POST", "/api/auth/google", json: sessionBody)
        let store = AnyValueStore<CloudLoginSession>.memory()
        let log = CloudSessionLog()
        let cloud = CloudClient(
            baseURL: URL(string: "https://cloud.example/")!, sessionStore: store, onSession: { log.record($0) },
            session: MockURLProtocol.makeSession())
        XCTAssertFalse(cloud.isSignedIn)

        let session = try await cloud.signInWithGoogle("google-id-token")

        XCTAssertEqual(session.sessionToken, "session-1")
        XCTAssertEqual(session.expiresAt, 1_800_000_000)
        XCTAssertEqual(session.user, CloudUser(email: "someone@example.com", name: "Someone"))
        XCTAssertTrue(cloud.isSignedIn)
        XCTAssertEqual(store.load(), session)
        XCTAssertEqual(log.seen, ["session-1"])
        let sent = try XCTUnwrap(rig.requests("POST", "/api/auth/google").first)
        XCTAssertEqual(sent.url.absoluteString, "https://cloud.example/api/auth/google")
        XCTAssertEqual(sent.json, ["id_token": "google-id-token"])
        XCTAssertNil(sent.headers["authorization"], "the exchange carries no bearer")
    }

    func testSendsTheSessionAsABearerAndSharesItAcrossCopies() async throws {
        rig.on("GET", "/api/cloud/me/namespaces", json: "[]")
        let cloud = client(token: "stored-token")
        let copy = cloud
        _ = try await copy.getMyNamespaces()
        XCTAssertEqual(rig.seen.first?.headers["authorization"], "Bearer stored-token")
        XCTAssertEqual(cloud.getSession()?.expiresAt, 0, "a handed-in token's expiry is unknown, not expired")
    }

    func testRestoresTheSessionFromItsStore() async throws {
        rig.on("GET", "/api/cloud/me/namespaces", json: "[]")
        let stored = CloudLoginSession(sessionToken: "kept", expiresAt: 5, user: CloudUser(email: "a@b.c"))
        let cloud = client(store: .memory(stored))
        XCTAssertEqual(cloud.getSession(), stored)
        _ = try await cloud.getMyNamespaces()
        XCTAssertEqual(rig.seen.first?.headers["authorization"], "Bearer kept")
    }

    func testRefusesAnAuthenticatedCallBeforeMakingItWhenNobodyIsSignedIn() async {
        do {
            _ = try await client().getMyNamespaces()
            XCTFail("expected a refusal")
        } catch AccountError.notSignedIn(let message) {
            XCTAssertTrue(message.contains("Not signed in"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testAdoptsARollingRefreshedSessionFromTheResponseHeaders() async throws {
        rig.on("GET", "/api/cloud/me/namespaces") { _ in
            .init(
                status: 200,
                headers: [
                    "Content-Type": "application/json", "x-mdma-session-refresh": "session-2",
                    "x-mdma-session-expires": "1900000000",
                ],
                body: Data("[]".utf8))
        }
        let log = CloudSessionLog()
        let store = AnyValueStore<CloudLoginSession>.memory()
        let cloud = client(token: "session-1", store: store, log: log)

        _ = try await cloud.getMyNamespaces()

        XCTAssertEqual(cloud.getSession()?.sessionToken, "session-2")
        XCTAssertEqual(cloud.getSession()?.expiresAt, 1_900_000_000)
        XCTAssertEqual(store.load()?.sessionToken, "session-2")
        XCTAssertEqual(log.seen, ["session-2"])
    }

    func testRefreshesExplicitly() async throws {
        rig.on("POST", "/api/auth/refresh", json: sessionBody)
        let cloud = client(token: "old")
        let session = try await cloud.refreshSession()
        XCTAssertEqual(session.sessionToken, "session-1")
        XCTAssertEqual(rig.seen.first?.headers["authorization"], "Bearer old")
    }

    func testSignsOutLocallyEvenWhenTheServerCallFails() async {
        rig.on("POST", "/api/auth/logout", status: 500, json: #"{"error":"down"}"#)
        let log = CloudSessionLog()
        let store = AnyValueStore<CloudLoginSession>.memory()
        let cloud = client(token: "session-1", store: store, log: log)
        do {
            try await cloud.signOut()
            XCTFail("the server failure is reported")
        } catch MeroError.http(let http) {
            XCTAssertEqual(http.status, 500)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(cloud.isSignedIn)
        XCTAssertNil(store.load())
        XCTAssertEqual(log.seen, [nil])
    }

    func testSignOutRevokesServerSide() async throws {
        rig.on("POST", "/api/auth/logout") { _ in .init(status: 200, headers: [:], body: Data("OK".utf8)) }
        let cloud = client(token: "session-1")
        try await cloud.signOut()
        XCTAssertEqual(rig.requests("POST", "/api/auth/logout").first?.headers["authorization"], "Bearer session-1")
        XCTAssertFalse(cloud.isSignedIn)
    }

    // MARK: - Signing in as an account (mdma `tests/test_account_login.py`)

    private let loginRootSecret = "5b6b8a1e9f2c47d3a80e6f14c2b9d75380af4e21c6d3b95f7e08a1c4d2f63b97"
    private let loginRootPublicKey = "a021d221f1e7601e8d280c857f8a667383e3923dda13b55f21ca2d928b79c70c"
    private let loginSignature =
        "5Au0t95Ei2dJLBES7w3i6qeH5NN90S2LyzloPIl1spCSBx4MV0M8VUgVaOT6a16SL/HGtj25epGHCPhj5wmeAw=="

    func testSignsInWithTheRootAndAdoptsTheSession() async throws {
        rig.on("GET", "/api/auth/account/challenge", json: #"{"nonce":"test-login-nonce-abc","expires_at_ms":1}"#)
        rig.on(
            "POST", "/api/auth/account",
            json: #"{"session_token":"session.jwt.value","expires_at":1893456000,"#
                + #""user":{"email":"owner@example.com"}}"#)
        let cloud = client()

        let session = try await cloud.signInWithAccount(.secret(loginRootSecret))

        XCTAssertEqual(session.sessionToken, "session.jwt.value")
        XCTAssertTrue(cloud.isSignedIn)
        let posted = try XCTUnwrap(rig.requests("POST", "/api/auth/account").first?.json)
        XCTAssertEqual(posted["root_public_key"]?.stringValue, loginRootPublicKey)
        XCTAssertEqual(posted["nonce"], "test-login-nonce-abc")
        XCTAssertNil(posted["account_id"], "the cloud derives the account from the key")
        // CryptoKit's Ed25519 is randomized: mdma's own signature pins the
        // domain, and ours verifies over the same bytes.
        let signature = try XCTUnwrap(posted["signature"]?.stringValue)
        let login = "calimero.mdma.account-login.v1\u{0}"
        XCTAssertTrue(
            try rootSigned(loginSignature, by: loginRootPublicKey, domain: login, nonce: "test-login-nonce-abc"))
        XCTAssertTrue(try rootSigned(signature, by: loginRootPublicKey, domain: login, nonce: "test-login-nonce-abc"))
        XCTAssertFalse(
            try rootSigned(
                signature, by: loginRootPublicKey, domain: "calimero.mdma.account-link.v1\u{0}",
                nonce: "test-login-nonce-abc"))
        XCTAssertTrue(rig.seen.allSatisfy { $0.headers["authorization"] == nil })
    }

    func testSignInWithAccountSurfacesAnUnlinkedAccount() async {
        rig.on("GET", "/api/auth/account/challenge", json: #"{"nonce":"n","expires_at_ms":1}"#)
        rig.on("POST", "/api/auth/account", status: 403, json: #"{"detail":"account not linked"}"#)
        do {
            _ = try await client().signInWithAccount(.secret(loginRootSecret))
            XCTFail("expected 403")
        } catch MeroError.http(let http) {
            XCTAssertEqual(http.status, 403)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSubmitsALoginProofSignedElsewhere() async throws {
        rig.on("GET", "/api/auth/account/challenge", json: #"{"nonce":"ext","expires_at_ms":1700000300000}"#)
        rig.on("POST", "/api/auth/account", json: sessionBody)
        let cloud = client()
        let challenge = try await cloud.getAccountLoginChallenge()
        XCTAssertEqual(challenge, AccountLoginChallenge(nonce: "ext", expiresAtMs: 1_700_000_300_000))
        let proof = AccountLoginProof(rootPublicKey: loginRootPublicKey, nonce: "ext", signature: "c2ln")
        _ = try await cloud.submitAccountLogin(proof)
        XCTAssertEqual(
            rig.requests("POST", "/api/auth/account").first?.json,
            ["root_public_key": .string(loginRootPublicKey), "nonce": "ext", "signature": "c2ln"])
    }

    // MARK: - Relays

    func testCarriesTheRelayNodeKeyUnderEitherSpelling() async throws {
        let key = String(repeating: "ab", count: 32)
        for field in ["node_key", "node_public_key"] {
            serveRelays([relayRow([field: .string(key)])])
            let relays = try await client(token: "t").getNamespaceRelays(ns)
            XCTAssertEqual(relays.first?.nodeKey, key, field)
        }
    }

    func testNeverSubstitutesPeerIdForTheNodeSigningKey() async throws {
        serveRelays([relayRow()])
        let relays = try await client(token: "t").getNamespaceRelays(ns)
        XCTAssertNil(relays.first?.nodeKey)
        XCTAssertEqual(relays.first?.peerId, "12D3KooWpeer")
    }

    func testMapsTheCloudWireShapeToTheRelayDescriptor() async throws {
        serveRelays([relayRow()])
        let relays = try await client(token: "t").getNamespaceRelays(ns)
        XCTAssertEqual(
            rig.seen.first?.url.absoluteString, "https://cloud.example/api/cloud/me/namespaces/\(ns)/relays")
        let expected = CloudRelay(
            peerId: "12D3KooWpeer", relayUrl: "https://relay.example", executorAccount: executor, nodeKey: nil,
            status: "active", authorshipReady: true, teeRole: "RelayTee", canExecute: true,
            lastSeenAt: "2026-01-01T00:00:00", confirmedAt: "2026-01-01T00:00:00", admission: nil,
            admissionHint: nil, join: nil)
        XCTAssertEqual(relays, [expected])
    }

    func testCarriesWhyARelayIsNotJoining() async throws {
        let reason = "identity d8c5 was removed from group b42f and cannot rejoin; an admin must re-add them"
        let join: JSONValue = [
            "state": "refused", "attempts": 4,
            "refusals": [["peer": "12D3KooWowner", "reason": .string(reason)]],
            "error": .null, "reported_at": "2026-10-06T02:58:25",
        ]
        serveRelays([
            relayRow([
                "status": "assigned", "admission": "refused",
                "admission_hint": "The node is alive, but the namespace owner has not admitted it.", "join": join,
            ])
        ])
        let relay = try await client(token: "t").getNamespaceRelays(ns).first
        XCTAssertEqual(relay?.admission, "refused")
        XCTAssertEqual(relay?.admissionHint?.contains("namespace owner"), true)
        let expected = CloudRelayJoin(
            state: "refused", attempts: 4, refusals: [CloudRelayRefusal(peer: "12D3KooWowner", reason: reason)],
            error: nil, reportedAt: "2026-10-06T02:58:25")
        XCTAssertEqual(relay?.join, expected)
    }

    func testReadsAMalformedJoinAsNoReport() async throws {
        serveRelays([
            relayRow(["peer_id": "a", "join": "refused"]),
            relayRow(["peer_id": "b", "join": ["attempts": 3]]),
            relayRow([
                "peer_id": "c",
                "join": ["state": "error", "refusals": "x", "error": "fleet-join failed: timed out after 90s"],
            ]),
        ])
        let relays = try await client(token: "t").getNamespaceRelays(ns)
        XCTAssertNil(relays[0].join)
        XCTAssertNil(relays[1].join)
        let expected = CloudRelayJoin(
            state: "error", attempts: 0, refusals: [], error: "fleet-join failed: timed out after 90s",
            reportedAt: nil)
        XCTAssertEqual(relays[2].join, expected)
    }

    func testTakesTheCloudsCanExecuteOverTheGrantBothWays() async throws {
        serveRelays([
            relayRow(["peer_id": "relay", "authorship_ready": false]),
            relayRow(["peer_id": "replica", "tee_role": "ReadOnlyTee", "can_execute": false]),
        ])
        let relays = try await client(token: "t").getNamespaceRelays(ns)
        XCTAssertEqual(relays[0].authorshipReady, false)
        XCTAssertEqual(relays[0].canExecute, true)
        XCTAssertEqual(relays[1].authorshipReady, true)
        XCTAssertEqual(relays[1].teeRole, "ReadOnlyTee")
        XCTAssertEqual(relays[1].canExecute, false)
    }

    func testFallsBackToTheGrantAgainstACloudThatSendsNoCanExecute() async throws {
        serveRelays([
            legacyRow(["peer_id": "granted"]), legacyRow(["peer_id": "waiting", "authorship_ready": false]),
            legacyRow(["peer_id": "no-url", "relay_url": .null]),
        ])
        let relays = try await client(token: "t").getNamespaceRelays(ns)
        XCTAssertEqual(relays.map(\.canExecute), [true, false, false])
        XCTAssertEqual(relays.map(\.teeRole), [nil, nil, nil])
    }

    func testTreatsAnOwnedNamespaceWithNoRelaysAsAnEmptyList() async throws {
        serveRelays([])
        let relays = try await client(token: "t").getNamespaceRelays(ns)
        XCTAssertEqual(relays, [])
    }

    func testFindExecutingRelaySkipsARelayMissingAnyPrecondition() async throws {
        let cases = [
            relayRow(["tee_role": "ReadOnlyTee", "can_execute": false]), relayRow(["can_execute": false]),
            relayRow(["relay_url": .null]), relayRow(["executor_account": .null]),
            legacyRow(["authorship_ready": false]),
        ]
        for row in cases {
            serveRelays([row])
            let found = try await client(token: "t").findExecutingRelay(ns)
            XCTAssertNil(found, "\(row)")
        }
    }

    func testFindExecutingRelayPicksTheUsableRelayOutOfAMixedSet() async throws {
        serveRelays([
            relayRow(["peer_id": "replica", "tee_role": "ReadOnlyTee", "can_execute": false]),
            relayRow(["peer_id": "ready", "authorship_ready": false]),
        ])
        let ready = try await client(token: "t").findExecutingRelay(ns)
        XCTAssertEqual(ready?.peerId, "ready")
        serveRelays([
            legacyRow(["peer_id": "waiting", "authorship_ready": false]), legacyRow(["peer_id": "granted"]),
        ])
        let legacy = try await client(token: "t").findExecutingRelay(ns)
        XCTAssertEqual(legacy?.peerId, "granted")
    }

    func testSurfacesTheCloudsNotFound() async {
        rig.on("GET", "/api/cloud/me/namespaces/\(ns)/relays", status: 404, json: #"{"detail":"No such namespace."}"#)
        do {
            _ = try await client(token: "t").getNamespaceRelays(ns)
            XCTFail("expected 404")
        } catch MeroError.http(let http) {
            XCTAssertEqual(http.status, 404)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Namespaces and machines

    func testMapsNamespaceRows() async throws {
        rig.on(
            "GET", "/api/cloud/me/namespaces",
            json: """
                [{"group_id":"\(ns)","namespace_id":"\(ns)","ha_status":"enabled","ha_enabled_at":"2026-01-01T00:00:00",
                  "contexts":["ctx-1"],"fleet_replicas":{"current":1,"limit":2}}]
                """)
        let namespaces = try await client(token: "t").getMyNamespaces()
        XCTAssertEqual(
            namespaces,
            [
                CloudNamespace(
                    namespaceId: ns, groupId: ns, haStatus: "enabled", haEnabledAt: "2026-01-01T00:00:00",
                    contexts: ["ctx-1"], fleetReplicas: ["current": 1, "limit": 2])
            ])
    }

    func testMapsTheAccountWideMachineView() async throws {
        rig.on(
            "GET", "/api/cloud/me/machines",
            json: """
                {"machines":[
                  {"peer_id":"12D3KooWpeer","relay_url":"https://relay.example","executor_account":"\(executor)",
                   "can_execute":true,"namespaces":[{"namespace_id":"\(ns)","status":"active","authorship_ready":true,
                   "tee_role":"RelayTee","fresh":true,"confirmed_at":"c","last_seen_at":"l"}]},
                  {"peer_id":"p","relay_url":"https://relay.example","executor_account":"\(executor)",
                   "can_execute":false,"namespaces":[{"namespace_id":"\(ns)","status":"active",
                   "authorship_ready":true,"tee_role":"ReadOnlyTee","fresh":false}]},
                  {"peer_id":"old","relay_url":"https://relay.example","executor_account":"\(executor)",
                   "namespaces":[{"namespace_id":"\(ns)","status":"active","authorship_ready":true}]}
                ]}
                """)
        let machines = try await client(token: "t").getMyMachines()
        XCTAssertEqual(
            machines.first,
            CloudMachine(
                peerId: "12D3KooWpeer", relayUrl: "https://relay.example", executorAccount: executor, canExecute: true,
                namespaces: [
                    CloudMachineNamespace(
                        namespaceId: ns, status: "active", authorshipReady: true, teeRole: "RelayTee", fresh: true,
                        confirmedAt: "c", lastSeenAt: "l")
                ]))
        XCTAssertEqual(machines[1].canExecute, false, "the cloud's verdict on a replica stands")
        XCTAssertEqual(machines[1].namespaces.first?.fresh, false)
        XCTAssertEqual(machines[2].canExecute, true, "an older cloud: derived from the grant")
        XCTAssertNil(machines[2].namespaces.first?.teeRole)
    }

    // MARK: - HA

    func testClaimNamespaceForwardsTheProofVerbatim() async throws {
        rig.on("POST", "/api/cloud/namespaces/claim", json: #"{"ok":true}"#)
        let proof: JSONValue = ["signerPublicKey": "ab", "signedPayload": "cd", "signature": "ef"]
        try await client(token: "t").claimNamespace(ns, ownershipProof: proof)
        XCTAssertEqual(
            rig.requests("POST", "/api/cloud/namespaces/claim").first?.json,
            ["namespace_id": .string(ns), "ownership_proof": proof])
    }

    func testEnableAndDisableHaPostToTheSplitEndpoints() async throws {
        rig.on("POST", "/api/cloud/namespaces/\(ns)/enable-ha", json: "{}")
        rig.on("POST", "/api/cloud/namespaces/\(ns)/disable-ha", json: "{}")
        let cloud = client(token: "t")
        let laptop = "/ip4/63.181.86.34/udp/4001/quic-v1/p2p/12D3KooWRelay/p2p-circuit/p2p/12D3KooWOwner"
        try await cloud.enableNamespaceHa(ns, admitterAddrs: [laptop])
        try await cloud.enableNamespaceHa(ns)
        try await cloud.disableNamespaceHa(ns)
        let enables = rig.requests("POST", "/api/cloud/namespaces/\(ns)/enable-ha").map { $0.json ?? .null }
        let expected: [JSONValue] = [["admitter_addrs": [.string(laptop)]], .object([:])]
        XCTAssertEqual(enables, expected)
        let disable = rig.requests("POST", "/api/cloud/namespaces/\(ns)/disable-ha").first?.json
        XCTAssertEqual(disable, JSONValue.object([:]))
    }

    func testEnableFoundedNamespaceHaPostsTheSessionClaim() async throws {
        rig.on("POST", "/api/cloud/me/namespaces/\(ns)/enable-ha", json: #"{"ha_status":"enabled"}"#)
        let proof = try await signAccountOwnershipClaim(
            AccountOwnershipClaimInput(
                namespaceId: ns, accountId: executor, salt: String(repeating: "cc", count: 32), credential: "dd",
                subject: "founder@example.com", deviceSecret: String(repeating: "07", count: 32)))
        let answer = try await client(token: "t").enableFoundedNamespaceHa(ns, ownershipProof: proof)
        XCTAssertEqual(answer["ha_status"], "enabled")
        let sent = rig.requests("POST", "/api/cloud/me/namespaces/\(ns)/enable-ha").first?.json
        XCTAssertEqual(sent?["groups"], JSONValue.array([]))
        XCTAssertEqual(sent?["ownership_proof"]?["kind"], "account")
        XCTAssertEqual(sent?["ownership_proof"]?["signed_payload"]?.stringValue, proof.signedPayload)
    }

    func testHaPageURLsCarryTheNamespaceContextAndRedirect() throws {
        let cloud = client()
        let enable = try cloud.enableHAURL(HAPageOptions(groupId: "g", contextId: "c", redirectUrl: "myapp://ha"))
        XCTAssertEqual(
            enable.absoluteString,
            "https://cloud.example/enable-ha?group_id=g&context_id=c&redirect_url=myapp%3A%2F%2Fha")
        let disable = try cloud.disableHAURL(HAPageOptions(groupId: "g", contextId: "c"))
        XCTAssertEqual(disable.absoluteString, "https://cloud.example/disable-ha?group_id=g&context_id=c")
    }

    func testTypedHaRefusals() {
        XCTAssertEqual(
            AccountError.haRefused(code: "account_not_linked", status: 409, body: nil).haRefusal, .accountNotLinked)
        XCTAssertEqual(
            AccountError.haRefused(code: "relay_not_dialable", status: 422, body: nil).haRefusal, .relayNotDialable)
        XCTAssertNil(AccountError.haRefused(code: "relay_not_dialable", status: 409, body: nil).haRefusal)
        XCTAssertNil(AccountError.invalidInput("x").haRefusal)
        XCTAssertEqual(HaRefusal.allCases.map(\.status), [409, 409, 409, 422, 422])
        XCTAssertEqual(HaRefusal.unknownRelay.code, "unknown_relay")
    }

    // MARK: - admitterAddrsFromNetworkStatus

    func testMakesEveryExternalAddressEndInThisNodesPeerId() {
        let peer = "12D3KooWOwner"
        let status: JSONValue = [
            "localPeerId": .string(peer),
            "listenAddrs": ["/ip4/0.0.0.0/tcp/2528"],
            "externalAddrs": [
                "/ip4/1.2.3.4/udp/2528/quic-v1", .string("/ip4/1.2.3.4/tcp/2528/p2p/\(peer)"),
                "/ip4/9.9.9.9/udp/4001/quic-v1/p2p/12D3KooWRelay/p2p-circuit", "not-a-multiaddr",
            ],
        ]
        let expected = [
            "/ip4/1.2.3.4/udp/2528/quic-v1/p2p/\(peer)", "/ip4/1.2.3.4/tcp/2528/p2p/\(peer)",
            "/ip4/9.9.9.9/udp/4001/quic-v1/p2p/12D3KooWRelay/p2p-circuit/p2p/\(peer)",
        ]
        XCTAssertEqual(admitterAddrsFromNetworkStatus(status), expected)
        XCTAssertEqual(admitterAddrsFromNetworkStatus(["data": status]), expected)
    }

    func testAdmitterAddrsAreEmptyWhenNothingIsDialable() {
        XCTAssertEqual(admitterAddrsFromNetworkStatus(nil), [])
        XCTAssertEqual(admitterAddrsFromNetworkStatus(.null), [])
        XCTAssertEqual(admitterAddrsFromNetworkStatus(["externalAddrs": ["/ip4/1.2.3.4/tcp/1"]]), [])
        XCTAssertEqual(admitterAddrsFromNetworkStatus(["localPeerId": "p", "externalAddrs": []]), [])
    }

    // MARK: - Account linking

    private let linkRootSecret = String(repeating: "42", count: 32)
    private let linkAccount = "a71c3dd073939d81f972525e9788c6b958818e33f30674ef43b4184eef40aa50"
    private let linkRootPublicKey = "2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12"

    func testLinkAccountFetchesAChallengeSignsItWithTheRootAndPostsTheProof() async throws {
        rig.on(
            "GET", "/api/cloud/me/accounts/challenge", json: #"{"nonce":"challenge-1","expires_at_ms":1700000300000}"#)
        rig.on(
            "POST", "/api/cloud/me/accounts",
            json: #"{"account_id":"\#(linkAccount)","linked_at":"2026-01-01T00:00:00","already_linked":false}"#)
        let link = try await client(token: "stored-token").linkAccount(.secret(linkRootSecret))
        XCTAssertEqual(
            link, CloudAccountLink(accountId: linkAccount, linkedAt: "2026-01-01T00:00:00", alreadyLinked: false))
        let posted = try XCTUnwrap(rig.requests("POST", "/api/cloud/me/accounts").first?.json)
        XCTAssertEqual(posted["account_id"]?.stringValue, linkAccount)
        XCTAssertEqual(posted["root_public_key"]?.stringValue, linkRootPublicKey)
        XCTAssertEqual(posted["nonce"], "challenge-1")
        let signature = try XCTUnwrap(posted["signature"]?.stringValue)
        XCTAssertNotNil(Data(base64Encoded: signature), "standard base64")
        XCTAssertTrue(
            try rootSigned(
                signature, by: linkRootPublicKey, domain: "calimero.mdma.account-link.v1\u{0}", nonce: "challenge-1"))
        for seen in rig.seen {
            XCTAssertFalse(String(decoding: seen.body, as: UTF8.self).contains(linkRootSecret))
            XCTAssertFalse(seen.url.absoluteString.contains(linkRootSecret))
        }
    }

    func testReportsAnIdempotentReLinkAsSuccess() async throws {
        rig.on("GET", "/api/cloud/me/accounts/challenge", json: #"{"nonce":"challenge-2"}"#)
        rig.on(
            "POST", "/api/cloud/me/accounts",
            json: #"{"account_id":"\#(linkAccount)","linked_at":null,"already_linked":true}"#)
        let link = try await client(token: "t").linkAccount(.secret(linkRootSecret))
        XCTAssertTrue(link.alreadyLinked)
        XCTAssertNil(link.linkedAt)
    }

    func testListsLinkedAccountsWithThePlanLimit() async throws {
        rig.on(
            "GET", "/api/cloud/me/accounts",
            json: #"{"accounts":[{"account_id":"\#(linkAccount)","linked_at":"l","has_recovery_envelope":true}],"#
                + #""limit":3}"#)
        let accounts = try await client(token: "t").getMyAccounts()
        XCTAssertEqual(
            accounts,
            CloudLinkedAccounts(
                accounts: [CloudLinkedAccount(accountId: linkAccount, linkedAt: "l", hasRecoveryEnvelope: true)],
                limit: 3))
        rig.on("GET", "/api/cloud/me/accounts", json: #"{"accounts":[]}"#)
        let unlimited = try await client(token: "t").getMyAccounts()
        XCTAssertNil(unlimited.limit)
    }

    func testLinkChallengeForAnExternalSigner() async throws {
        rig.on(
            "GET", "/api/cloud/me/accounts/challenge", json: #"{"nonce":"challenge-9","expires_at_ms":1700000300000}"#)
        let challenge = try await client(token: "t").getAccountLinkChallenge()
        XCTAssertEqual(challenge, AccountLinkChallenge(nonce: "challenge-9", expiresAtMs: 1_700_000_300_000))
        rig.on("GET", "/api/cloud/me/accounts/challenge", json: #"{"nonce":"challenge-10"}"#)
        let open = try await client(token: "t").getAccountLinkChallenge()
        XCTAssertNil(open.expiresAtMs)
    }

    func testPostsALinkProofAssembledElsewhereVerbatim() async throws {
        rig.on("POST", "/api/cloud/me/accounts", json: #"{"account_id":"\#(linkAccount)","already_linked":false}"#)
        let result = try await client(token: "t").submitAccountLink(
            AccountLinkProof(
                accountId: linkAccount, rootPublicKey: linkRootPublicKey, nonce: "challenge-11",
                signature: "c2lnbmF0dXJl"))
        XCTAssertEqual(result.accountId, linkAccount)
        XCTAssertEqual(
            rig.requests("POST", "/api/cloud/me/accounts").first?.json,
            [
                "account_id": .string(linkAccount), "root_public_key": .string(linkRootPublicKey),
                "nonce": "challenge-11", "signature": "c2lnbmF0dXJl",
            ])
    }
}
