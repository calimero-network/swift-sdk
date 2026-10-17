import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `connect.test.ts`: `connectCloud` / `connectCloudWithAccount`
/// against a scripted cloud and relay.
final class ConnectCloudTests: XCTestCase {
    private var rig: CloudRig!
    private let cloudURL = URL(string: "https://cloud.example")!
    private let ns = String(repeating: "01", count: 32)
    private let otherNs = String(repeating: "02", count: 32)
    private let context = String(repeating: "03", count: 32)
    private let executor = String(repeating: "4d", count: 32)
    private let keys = try! DeviceKeys(
        signSecret: Data(repeating: 0x77, count: 32), kemSecret: Data(repeating: 0x78, count: 32))
    private let wallet = TestWallet()

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

    private func json(_ value: JSONValue) -> String { String(decoding: CanonicalJSON.data(value), as: UTF8.self) }

    private func namespaceRow(_ id: String, ha: String = "enabled") -> JSONValue {
        [
            "group_id": .string(id), "namespace_id": .string(id), "ha_status": .string(ha), "ha_enabled_at": .null,
            "contexts": [], "fleet_replicas": [:],
        ]
    }

    private func readyRelay(_ over: [String: JSONValue] = [:]) -> JSONValue {
        var row: [String: JSONValue] = [
            "peer_id": "12D3KooWready", "relay_url": "https://relay.example", "executor_account": .string(executor),
            "status": "active", "authorship_ready": true, "tee_role": "RelayTee", "can_execute": true,
        ]
        row.merge(over) { _, new in new }
        return .object(row)
    }

    private func serve(namespaces: [JSONValue], relays: [JSONValue]? = nil, relaysOf id: String? = nil) {
        rig.on("GET", "/api/cloud/me/namespaces", json: json(.array(namespaces)))
        if let relays {
            rig.on("GET", "/api/cloud/me/namespaces/\(id ?? ns)/relays", json: json(["relays": .array(relays)]))
        }
    }

    private func serveRelayWrites() {
        rig.on(
            "GET", "/admin-api/contexts/\(context)/intents",
            json: json([
                "data": [
                    "executorAccount": .string(executor), "executorKey": .string(String(repeating: "ec", count: 32)),
                    "canAuthorOnBehalf": true, "groupId": .string(String(repeating: "ab", count: 32)),
                    "releaseBytecodeId": .string(String(repeating: "b1", count: 32)), "releaseVersion": "1.2.0",
                ]
            ]))
        rig.on(
            "POST", "/admin-api/contexts/\(context)/intents", json: #"{"data":{"rootHash":"root-1","returns":"ok"}}"#)
    }

    private func options(
        sessionToken: String? = "session-1", googleIdToken: String? = nil, namespaceId: String? = nil,
        relayNodeKey: String? = nil
    ) -> ConnectCloudOptions {
        let enrolled = wallet.approve(keys, state: nil)
        return ConnectCloudOptions(
            authorAccount: enrolled.account, authorProof: enrolled.credential, keys: keys,
            config: CloudConfig(cloudBaseURL: cloudURL), sessionToken: sessionToken, googleIdToken: googleIdToken,
            namespaceId: namespaceId, nonces: MemoryWarrantNonceStore(), relayNodeKey: relayNodeKey,
            urlSession: MockURLProtocol.makeSession())
    }

    /// The message of the ``AccountError/cloudNotReady(_:)`` `connectCloud` throws.
    private func notReadyMessage(_ options: ConnectCloudOptions) async -> String {
        do {
            _ = try await connectCloud(options)
            XCTFail("expected cloudNotReady")
        } catch AccountError.cloudNotReady(let message) {
            return message
        } catch {
            XCTFail("unexpected \(error)")
        }
        return ""
    }

    // MARK: - connectCloud

    func testSignsInFindsTheNamespaceAndItsRelayAndCanWrite() async throws {
        serve(namespaces: [namespaceRow(ns)], relays: [readyRelay()])
        serveRelayWrites()

        let connection = try await connectCloud(options())

        XCTAssertEqual(connection.namespaceId, ns)
        XCTAssertEqual(connection.namespace?.haStatus, "enabled")
        XCTAssertEqual(connection.relayInfo?.executorAccount, executor)
        XCTAssertEqual(connection.session.relayUrl, "https://relay.example")
        XCTAssertEqual(connection.session.device, wallet.approve(keys, state: nil).device)
        XCTAssertEqual(connection.cloud?.getSession()?.sessionToken, "session-1")
        XCTAssertNotNil(connection.presence)
        XCTAssertNotNil(connection.readNote, "the relay did not attest, so reads are off; writes work")

        let result = try await connection.execute(contextId: context, method: "set", argsJson: ["key": "k"])
        XCTAssertEqual(result.rootHash, "root-1")
        let writes = rig.requests("POST", "/admin-api/contexts/\(context)/intents")
        XCTAssertEqual(writes.map { $0.url.host }, ["relay.example"])
        XCTAssertFalse(rig.seen.contains { $0.url.host == "cloud.example" && $0.url.path.contains("/intents") })
        let bearers = rig.requests("GET", "/api/cloud/me/namespaces").map { $0.headers["authorization"] }
        XCTAssertEqual(bearers, ["Bearer session-1"])
    }

    /// With `seal`, the relay is attested by this client and the intent
    /// never crosses in the clear: here the verifier refuses the relay's
    /// quote, so the write fails before anything but the attestation reached
    /// the relay. The cloud calls stay plain; they carry no intent.
    func testAttestsAndSealsToTheRelayWhenAskedAndSendsNoIntentInTheClear() async throws {
        serve(namespaces: [namespaceRow(ns)], relays: [readyRelay()])
        serveRelayWrites()
        rig.on(
            "POST", "/admin-api/tee/attest",
            json: #"{"data":{"quoteB64":"AA==","transportPublicKey":"\#(String(repeating: "11", count: 32))"}}"#)
        var sealed = options()
        sealed.seal = AnyTransportQuoteVerifier { _ in false }
        let connection = try await connectCloud(sealed)
        defer { SealedURLProtocol.unregisterAll() }
        do {
            _ = try await connection.execute(contextId: context, method: "set", argsJson: ["key": "k"])
            XCTFail("a relay whose quote is refused must not be written to")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("did not verify"), message)
        }
        XCTAssertFalse(rig.requests("POST", "/admin-api/tee/attest").isEmpty)
        XCTAssertFalse(rig.seen.contains { $0.url.path.contains("/intents") })
        XCTAssertFalse(rig.requests("GET", "/api/cloud/me/namespaces").isEmpty)
    }

    func testExchangesAGoogleIdTokenWhenNoSessionTokenIsHeld() async throws {
        rig.on(
            "POST", "/api/auth/google",
            json: #"{"session_token":"session-fresh","expires_at":1,"user":{"email":"a@b.c"}}"#)
        serve(namespaces: [namespaceRow(ns)], relays: [readyRelay()])
        let connection = try await connectCloud(options(sessionToken: nil, googleIdToken: "google-id"))
        XCTAssertEqual(rig.seen.first?.url.absoluteString, "https://cloud.example/api/auth/google")
        XCTAssertEqual(connection.cloud?.getSession()?.sessionToken, "session-fresh")
    }

    func testNeedsOneCredentialOrTheOther() async {
        do {
            _ = try await connectCloud(options(sessionToken: nil))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("sessionToken or a googleIdToken"), "\(error)")
        }
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testRefusesToGuessBetweenSeveralOwnedNamespaces() async {
        serve(namespaces: [namespaceRow(ns), namespaceRow(otherNs)])
        let message = await notReadyMessage(options())
        XCTAssertTrue(message.contains("owns 2 namespaces — pass namespaceId"), message)
    }

    func testHonoursAnExplicitNamespaceIdAndNamesTheOwnedSetWhenItIsWrong() async throws {
        serve(namespaces: [namespaceRow(ns), namespaceRow(otherNs)], relays: [readyRelay()], relaysOf: otherNs)
        let connection = try await connectCloud(options(namespaceId: otherNs))
        XCTAssertEqual(connection.namespaceId, otherNs)

        serve(namespaces: [namespaceRow(ns)])
        let message = await notReadyMessage(options(namespaceId: otherNs))
        XCTAssertTrue(message.contains("owns no namespace \(otherNs)"), message)
        XCTAssertTrue(message.contains(ns), message)
    }

    func testSaysToClaimANamespaceWhenTheAccountOwnsNone() async {
        serve(namespaces: [])
        let message = await notReadyMessage(options())
        XCTAssertTrue(message.contains("owns no namespaces"), message)
    }

    func testSaysToEnableHaWhenThereAreNoRelaysAndHaIsOff() async {
        serve(namespaces: [namespaceRow(ns, ha: "none")], relays: [])
        let message = await notReadyMessage(options())
        XCTAssertTrue(message.contains("enable HA on it in the cloud"), message)
    }

    func testSaysToRetryWhenHaIsOnButNothingIsAssignedYet() async {
        serve(namespaces: [namespaceRow(ns)], relays: [])
        let message = await notReadyMessage(options())
        XCTAssertTrue(message.contains("no relay has been assigned to it yet"), message)
    }

    func testNamesTheAccountAnAdminMustGrantWhenEveryRelayLacksTheCapability() async {
        var legacy = readyRelay(["authorship_ready": false]).objectValue ?? [:]
        legacy.removeValue(forKey: "tee_role")
        legacy.removeValue(forKey: "can_execute")
        serve(namespaces: [namespaceRow(ns)], relays: [.object(legacy)])
        let message = await notReadyMessage(options())
        XCTAssertTrue(message.contains("CAN_AUTHOR_ON_BEHALF"), message)
        XCTAssertTrue(message.contains(executor), message)
    }

    func testPointsAtTheTeeAdmissionPolicyWhenEveryNodeIsAReplica() async {
        let replica = readyRelay(["tee_role": "ReadOnlyTee", "can_execute": false])
        serve(namespaces: [namespaceRow(ns)], relays: [replica])
        let message = await notReadyMessage(options())
        XCTAssertTrue(message.contains("ReadOnlyTee"), message)
        XCTAssertTrue(message.contains("mode: 'relay'"), message)
        XCTAssertFalse(message.contains("CAN_AUTHOR_ON_BEHALF"), message)
    }

    func testConnectsThroughARelayTeeThatHoldsNoGrant() async throws {
        serve(namespaces: [namespaceRow(ns)], relays: [readyRelay(["authorship_ready": false])])
        let connection = try await connectCloud(options())
        XCTAssertEqual(connection.relayInfo?.peerId, "12D3KooWready")
    }

    func testAKnownRelayNodeKeySkipsAttestation() async throws {
        serve(namespaces: [namespaceRow(ns)], relays: [readyRelay()])
        _ = try await connectCloud(options(relayNodeKey: String(repeating: "ec", count: 32)))
        XCTAssertTrue(rig.requests("POST", "/admin-api/tee/attest").isEmpty)
    }

    func testCloudNotReadyClassifiesAsUnavailable() {
        XCTAssertEqual(classifyError(AccountError.cloudNotReady("x")).kind, .unavailable)
        XCTAssertEqual(classifyError(AccountError.linkDeclined("x")).kind, .forbidden)
    }

    // MARK: - connectCloudWithAccount

    private let rootSecret = String(repeating: "5b", count: 32)

    private func serveAccountCloud() {
        rig.on("GET", "/api/auth/account/challenge", json: #"{"nonce":"login-nonce","expires_at_ms":1}"#)
        rig.on(
            "POST", "/api/auth/account",
            json: #"{"session_token":"session-from-root","expires_at":1893456000,"#
                + #""user":{"email":"owner@example.com"}}"#)
        serve(namespaces: [namespaceRow(ns)], relays: [readyRelay()])
        serveRelayWrites()
    }

    private func accountOptions(
        authorAccount: String? = nil, log: CloudSessionLog? = nil
    ) -> ConnectCloudWithAccountOptions {
        var onSession: (@Sendable (CloudLoginSession?) -> Void)?
        if let log { onSession = { log.record($0) } }
        return ConnectCloudWithAccountOptions(
            root: .secret(rootSecret), authorProof: wallet.approve(keys, state: nil).credential, keys: keys,
            authorAccount: authorAccount, config: CloudConfig(cloudBaseURL: cloudURL), onSession: onSession,
            nonces: MemoryWarrantNonceStore(), urlSession: MockURLProtocol.makeSession())
    }

    /// The author account a warrant names: context (32) ‖ author account (32) ‖ ….
    private func warrantAuthor() throws -> String {
        let intent = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(context)/intents").first)
        let warrant = try XCTUnwrap(intent.json?["warrant"]?.stringValue)
        return String(warrant.dropFirst(64).prefix(64))
    }

    func testSignsInWithTheRootAndCarriesThatSessionIntoTheRelayLookup() async throws {
        serveAccountCloud()
        let log = CloudSessionLog()
        let connection = try await connectCloudWithAccount(accountOptions(log: log))
        let cloudCalls = rig.seen.filter { $0.url.host == "cloud.example" }.map(\.url.path)
        let expected = [
            "/api/auth/account/challenge", "/api/auth/account", "/api/cloud/me/namespaces",
            "/api/cloud/me/namespaces/\(ns)/relays",
        ]
        XCTAssertEqual(cloudCalls, expected)
        XCTAssertEqual(connection.cloud?.getSession()?.sessionToken, "session-from-root")
        XCTAssertEqual(connection.cloud?.getSession()?.user.email, "owner@example.com")
        XCTAssertEqual(connection.namespaceId, ns)
        XCTAssertTrue(log.seen.contains("session-from-root"))
    }

    func testWritesAsTheAccountTheRootDerivesWithoutBeingTold() async throws {
        serveAccountCloud()
        let connection = try await connectCloudWithAccount(accountOptions())
        _ = try await connection.execute(contextId: context, method: "set")
        XCTAssertEqual(try warrantAuthor(), try accountRootFromSecret(rootSecret).accountId)
    }

    func testLetsAnExplicitAuthorAccountOverrideTheSigningRoot() async throws {
        serveAccountCloud()
        let author = String(repeating: "0e", count: 32)
        let connection = try await connectCloudWithAccount(accountOptions(authorAccount: author))
        _ = try await connection.execute(contextId: context, method: "set")
        XCTAssertEqual(try warrantAuthor(), author)
    }
}
