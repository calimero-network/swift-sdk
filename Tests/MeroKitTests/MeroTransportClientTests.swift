import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `src/transport/mero-client.test.ts`: one call site, two
/// transports.
final class MeroTransportClientTests: XCTestCase {
    private var rig: CloudRig!
    private let ctx = DelegatedFixture.rep("11")

    override func setUp() {
        super.setUp()
        rig = CloudRig()
        rig.install()
        MethodKinds.shared.clear()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        rig = nil
        super.tearDown()
    }

    private func nodeClient() -> MeroTransportClient {
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!), session: MockURLProtocol.makeSession())
        return MeroTransportClient(mero: mero)
    }

    private func relayClient(
        sessionToken: (@Sendable () async -> String?)? = nil, nodeKey: String? = nil, proof: Bool = false
    ) throws -> MeroTransportClient {
        let relay = DelegatedFixture.relayClient()
        return try MeroTransportClient(
            .relay(
                RelayTransportConfig(
                    relay: relay, sessionToken: sessionToken,
                    observe: RelayObserveConfig(nodeKey: nodeKey, audience: .codeSigningId("network.calimero.test")),
                    proof: proof ? ProofCredential(credential: relay.authorProof, keys: DelegatedFixture.keys) : nil,
                    urlSession: MockURLProtocol.makeSession())))
    }

    private func serveNode(output: String) {
        rig.on("POST", "/jsonrpc", json: #"{"jsonrpc":"2.0","id":1,"result":{"output":\#(output)}}"#)
    }

    private func serveIntent(returns: String, rootHash: String = "ff") {
        DelegatedFixture.serveDescribe(rig, ctx: ctx)
        rig.on(
            "POST", "/admin-api/contexts/\(ctx)/intents",
            json: #"{"data":{"returns":\#(returns),"rootHash":"\#(rootHash)"}}"#)
    }

    // MARK: - One call site, two transports

    func testReturnsTheSameValueThroughTheNodeAndThroughARelay() async throws {
        serveNode(output: #""v""#)
        serveIntent(returns: #""v""#)
        let node = nodeClient()
        let relay = try relayClient()
        for client in [node, relay] {
            let value: String = try await client.rpc.execute(contextId: ctx, method: "get", argsJson: ["key": "k"])
            XCTAssertEqual(value, "v")
        }
        XCTAssertEqual(node.transport, .node)
        XCTAssertEqual(relay.transport, .relay)
        XCTAssertEqual(relay.rpc.kind, .relay)
    }

    func testSendsTheSameMethodAndArgumentsOnBothTransports() async throws {
        serveNode(output: "1")
        serveIntent(returns: "1")
        let _: Int = try await nodeClient().rpc.execute(contextId: ctx, method: "set", argsJson: ["key": "k"])
        let _: Int = try await relayClient().rpc.execute(contextId: ctx, method: "set", argsJson: ["key": "k"])
        let rpc = try XCTUnwrap(rig.requests("POST", "/jsonrpc").first?.json)
        XCTAssertEqual(rpc["params"]?["method"], "set")
        XCTAssertEqual(rpc["params"]?["argsJson"], ["key": "k"])
        let intent = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").first?.json)
        XCTAssertEqual(intent["method"], "set")
        XCTAssertEqual(intent["argsJson"], ["key": "k"])
    }

    func testDefaultsArgsJsonToAnEmptyObjectOnTheRelay() async throws {
        serveIntent(returns: "2")
        let pending = try await relayClient().rpc.countMyPending(ctx)
        XCTAssertEqual(pending, 2)
        let intent = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").first?.json)
        XCTAssertEqual(intent["method"], "count_my_pending")
        XCTAssertEqual(intent["argsJson"], [:])
    }

    func testReportsANullReturnAsNilOnTheRelay() async throws {
        serveIntent(returns: "null")
        let value: String? = try await relayClient().rpc.execute(contextId: ctx, method: "get", argsJson: [:])
        XCTAssertNil(value)
    }

    func testMigrateMyEntriesGoesThroughTheRelayAsAPlainMethod() async throws {
        serveIntent(returns: #"{"converted":3,"remaining":1}"#)
        let summary = try await relayClient().rpc.migrateMyEntries(ctx)
        XCTAssertEqual(summary, MigrateMyEntriesSummary(converted: 3, remaining: 1))
    }

    func testSurfacesTheRootHashThroughExecuteWithMetadataOnly() async throws {
        serveIntent(returns: #""ok""#, rootHash: "ab")
        serveNode(output: #""ok""#)
        let relayed: ExecuteResult<String> = try await relayClient().rpc.executeWithMetadata(
            contextId: ctx, method: "set", argsJson: [:])
        XCTAssertEqual(relayed, ExecuteResult(returns: "ok", transport: .relay, rootHash: "ab"))
        let direct: ExecuteResult<String> = try await nodeClient().rpc.executeWithMetadata(
            contextId: ctx, method: "set", argsJson: [:])
        XCTAssertEqual(direct.transport, .node)
        XCTAssertNil(direct.rootHash, "the node reports none, and none is invented")
    }

    // MARK: - Selection

    func testHandsBackTheRelayClientItWasGiven() throws {
        let client = try relayClient()
        XCTAssertEqual(try client.relay.relayURL, DelegatedFixture.relay)
        XCTAssertThrowsError(try nodeClient().relay) {
            XCTAssertEqual($0 as? MeroTransportError, .nodeHasNoRelay)
        }
        XCTAssertNoThrow(try nodeClient().node)
        XCTAssertNoThrow(try nodeClient().cloud)
    }

    // MARK: - A relay client with no node key

    func testARelayClientWithNoNodeKeyCannotSubscribeAndSaysWhy() async throws {
        let client = try relayClient()
        XCTAssertFalse(client.canSubscribe)
        XCTAssertFalse(client.rpc.canSubscribe)
        XCTAssertThrowsError(try client.events) {
            XCTAssertEqual($0 as? MeroTransportError, .missingNodeKey(surface: "SSE events"))
            XCTAssertTrue($0.localizedDescription.contains("does serve /sse and /ws"))
        }
        XCTAssertThrowsError(try client.ws)
        XCTAssertThrowsError(try client.node)
        XCTAssertThrowsError(try client.cloud)
        do {
            _ = try await client.admin
            XCTFail("no admin without a session or a proof")
        } catch {
            XCTAssertEqual(error as? MeroTransportError, .noAdminCredential)
        }
        do {
            _ = try await client.auth
            XCTFail("a relay issues no node credential")
        } catch {
            XCTAssertNotNil(error as? MeroTransportError)
        }
        await client.close()
    }

    func testServesEphemeralAsAnAccountPresenceClientWithNoNodeKey() async throws {
        let client = try relayClient()
        guard case .relay = try await client.ephemeral else { return XCTFail("expected the relay presence client") }
        guard case .node = try await nodeClient().ephemeral else { return XCTFail("expected the node client") }
    }

    func testServesAdminOnceASessionIsSuppliedAndSendsThatToken() async throws {
        rig.on("GET", "/admin-api/namespaces", json: #"{"data":[]}"#)
        let client = try relayClient(sessionToken: { "relay-session" })
        let namespaces = try await client.admin.listNamespaces()
        XCTAssertTrue(namespaces.isEmpty)
        let read = try XCTUnwrap(rig.requests("GET", "/admin-api/namespaces").first)
        XCTAssertEqual(read.headers["authorization"], "Bearer relay-session")
        XCTAssertNil(read.headers["x-calimero-proof"])
    }

    // MARK: - A relay client with the device certificate

    func testAProofAuthenticatesAdminAndEventsButNotTheWebSocket() async throws {
        rig.on("GET", "/admin-api/contexts", json: #"{"data":{"contexts":[]}}"#)
        let client = try relayClient(proof: true)
        XCTAssertTrue(client.canSubscribe)
        _ = try await client.admin.getContexts()
        let read = try XCTUnwrap(rig.requests("GET", "/admin-api/contexts").first)
        XCTAssertNotNil(read.headers["x-calimero-proof"])
        XCTAssertNil(read.headers["authorization"])
        XCTAssertTrue(try client.events === client.events, "one stream, not one per read")
        XCTAssertThrowsError(try client.ws) {
            XCTAssertEqual($0 as? MeroTransportError, .proofCannotOpenWebSocket)
        }
    }

    // MARK: - A relay client given the node key

    func testARelayClientGivenTheNodeKeyCanSubscribe() throws {
        let client = try relayClient(nodeKey: DelegatedFixture.nodeKey)
        XCTAssertTrue(client.canSubscribe)
        XCTAssertTrue(client.rpc.canSubscribe)
        XCTAssertTrue(try client.events === client.events)
        XCTAssertTrue(try client.ws === client.ws)
        XCTAssertTrue(rig.seen.isEmpty, "reading the surfaces sends nothing")
    }

    func testTheObserverLogsInWithTheAccountProofForThePinnedKey() async throws {
        DelegatedFixture.serveLogin(rig)
        let relay = DelegatedFixture.relayClient()
        let observer = RelayObserver(
            nodeURL: relay.relayURL, nodeKey: DelegatedFixture.nodeKey, accountProof: relay.authorProof,
            keys: DelegatedFixture.keys, audience: .codeSigningId("network.calimero.test"),
            session: MockURLProtocol.makeSession())
        let token = try await observer.accessToken()
        XCTAssertEqual(token, "relay-access")
        let body = try XCTUnwrap(rig.requests("POST", "/auth/token").first?.json)
        XCTAssertEqual(body["auth_method"], "account_proof")
        XCTAssertEqual(body["provider_data"]?["account_proof"]?.stringValue, relay.authorProof)
        let statement = try Hex.decodeUnsized(
            body["provider_data"]?["login_statement"]?.stringValue ?? "", label: "statement")
        XCTAssertEqual(Hex.encode(statement.prefix(32)), DelegatedFixture.nodeKey, "signed about the pinned key")
    }

    func testTheObserverMintsOneSessionWhenTwoSurfacesAskAtOnce() async throws {
        DelegatedFixture.serveLogin(rig, accessToken: DelegatedFixture.jwt(exp: Date().timeIntervalSince1970 + 3600))
        let observer = RelayObserver(
            nodeURL: DelegatedFixture.relay, nodeKey: DelegatedFixture.nodeKey,
            accountProof: DelegatedFixture.enrolled.credential, keys: DelegatedFixture.keys,
            audience: .cli, session: MockURLProtocol.makeSession())
        async let first = observer.accessToken()
        async let second = observer.accessToken()
        let tokens = try await [first, second]
        XCTAssertEqual(tokens[0], tokens[1])
        _ = try await observer.accessToken()
        XCTAssertEqual(rig.requests("POST", "/auth/token").count, 1, "one login, kept until it nears expiry")
    }

    func testTheObserverMintsAgainNearExpiry() async throws {
        let soon = Date().timeIntervalSince1970 + 10
        DelegatedFixture.serveLogin(rig, accessToken: DelegatedFixture.jwt(exp: soon))
        let observer = RelayObserver(
            nodeURL: DelegatedFixture.relay, nodeKey: DelegatedFixture.nodeKey,
            accountProof: DelegatedFixture.enrolled.credential, keys: DelegatedFixture.keys,
            audience: .cli, session: MockURLProtocol.makeSession())
        _ = try await observer.accessToken()
        _ = try await observer.accessToken()
        XCTAssertEqual(rig.requests("POST", "/auth/token").count, 2, "inside the 30 s skew: log in again")
    }
}
