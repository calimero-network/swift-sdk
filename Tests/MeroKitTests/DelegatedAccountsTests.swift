import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `account/session.ts`'s relay map, nonces and relay keys
/// (`nonces.test.ts`, `relay-node-key.test.ts`, `delegated-client.test.ts`).
final class DelegatedAccountsTests: XCTestCase {
    private var rig: CloudRig!
    private let relay = DelegatedFixture.relay
    private let ctx = DelegatedFixture.rep("03")
    private let ns = DelegatedFixture.rep("01")

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

    // MARK: - Relay map

    func testRemembersWhichRelayServesANamespaceAndAContext() {
        let store = DelegatedAccountStore.memory()
        let account = DelegatedFixture.session().account
        DelegatedAccounts.rememberRelay(account, relayURL: relay + "/", namespaceId: ns, contextId: ctx, store: store)
        XCTAssertEqual(
            DelegatedAccounts.readRelayMap(account, store: store),
            RelayMap(namespaces: [ns: relay], contexts: [ctx: relay]))
        XCTAssertEqual(DelegatedAccounts.relayForContext(account, contextId: ctx, store: store), relay)
        XCTAssertNil(DelegatedAccounts.relayForContext(account, contextId: ns, store: store))
        XCTAssertEqual(DelegatedAccounts.readRelayMap("someone-else", store: store), RelayMap())
    }

    func testKnownRelaysAreTheSessionsFirstThenEachInTheMapOnce() {
        let store = DelegatedAccountStore.memory()
        let session = DelegatedFixture.session()
        DelegatedAccounts.rememberRelay(session.account, relayURL: "https://b.test", namespaceId: ns, store: store)
        DelegatedAccounts.rememberRelay(session.account, relayURL: relay, contextId: ctx, store: store)
        XCTAssertEqual(DelegatedAccounts.knownRelays(session, store: store), [relay, "https://b.test"])
        XCTAssertEqual(DelegatedAccounts.knownRelays(session.on(relay: nil), store: store), ["https://b.test", relay])
    }

    func testCarriesTheExecutorOnlyOnTheSameRelay() {
        let before = DelegatedFixture.session(executorAccount: DelegatedFixture.rep("33"))
        let same = DelegatedFixture.session(relayUrl: relay + "/")
        XCTAssertEqual(
            DelegatedAccounts.carryExecutorAccount(from: before, to: same).executorAccount, DelegatedFixture.rep("33"))
        let moved = DelegatedFixture.session(relayUrl: "https://other.test")
        XCTAssertNil(DelegatedAccounts.carryExecutorAccount(from: before, to: moved).executorAccount)
        XCTAssertNil(DelegatedAccounts.carryExecutorAccount(from: nil, to: same).executorAccount)
        let named = DelegatedFixture.session(executorAccount: DelegatedFixture.rep("44"))
        XCTAssertEqual(
            DelegatedAccounts.carryExecutorAccount(from: before, to: named).executorAccount, DelegatedFixture.rep("44"))
    }

    func testTheNamespaceOfAGroupIsItselfOrWhatWasRemembered() {
        let store = DelegatedAccountStore.memory()
        let session = DelegatedFixture.session()
        let sub = DelegatedFixture.rep("02")
        XCTAssertNil(DelegatedAccounts.namespaceOfGroup(session, groupId: ns, store: store))
        DelegatedAccounts.rememberRelay(session.account, relayURL: relay, namespaceId: ns, store: store)
        XCTAssertEqual(DelegatedAccounts.namespaceOfGroup(session, groupId: ns, store: store), ns)
        XCTAssertNil(DelegatedAccounts.namespaceOfGroup(session, groupId: sub, store: store))
        DelegatedAccounts.rememberGroupNamespace(session.account, groupId: sub, namespaceId: ns, store: store)
        XCTAssertEqual(DelegatedAccounts.namespaceOfGroup(session, groupId: sub, store: store), ns)
    }

    func testTheStatePersistsInUserDefaults() throws {
        let suite = "merokit.delegated.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let written = DelegatedAccountStore.userDefaults(defaults)
        written.rememberRelay(account: "AA", relayURL: relay, namespaceId: ns)
        written.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("AB"))
        let read = DelegatedAccountStore.userDefaults(defaults)
        XCTAssertEqual(read.relayMap(account: "aa").namespaces, [ns: relay])
        XCTAssertEqual(read.pinnedRelayNodeKey(relayURL: relay + "/"), DelegatedFixture.rep("ab"))
        read.pinRelayNodeKey(relayURL: relay, nodeKey: "not-a-key")
        XCTAssertNil(read.pinnedRelayNodeKey(relayURL: relay), "a malformed pin is no pin")
    }

    // MARK: - Nonces

    func testOneRisingSequencePerRelayStartsAboveASpentCreationNonce() {
        let nonces = MemoryWarrantNonceStore()
        XCTAssertEqual(nonces.next(relay: relay), 1)
        DelegatedAccounts.markContextNonceSpent(relayURL: relay + "/", contextId: ctx, nonce: 7, nonces: nonces)
        XCTAssertEqual(nonces.next(relay: relay), 8)
        DelegatedAccounts.markContextNonceSpent(relayURL: relay, contextId: ctx, nonce: 2, nonces: nonces)
        XCTAssertEqual(nonces.next(relay: relay), 9, "never backwards")
        XCTAssertEqual(nonces.next(relay: "https://other.test"), 1, "relays are kept apart")
    }

    // MARK: - Relay node key

    func testAPinnedKeyIsUsedWithoutAskingTheRelay() async {
        let env = DelegatedFixture.environment()
        env.store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("ab"))
        let key = await DelegatedAccounts.resolveRelayNodeKey(relay, env: env)
        XCTAssertEqual(key, DelegatedFixture.rep("ab"))
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testLearnsTheKeyFromTheAttestationAndPinsIt() async {
        DelegatedFixture.serveAttest(rig)
        let env = DelegatedFixture.environment()
        let attempt = await DelegatedAccounts.attemptRelayNodeKey(relay, env: env)
        XCTAssertEqual(attempt.nodeKey, DelegatedFixture.nodeKey)
        XCTAssertEqual(env.store.pinnedRelayNodeKey(relayURL: relay), DelegatedFixture.nodeKey)
        // `fresh` attests again even with the key pinned.
        _ = await DelegatedAccounts.attemptRelayNodeKey(relay, fresh: true, env: env)
        XCTAssertEqual(rig.requests("POST", "/admin-api/tee/attest").count, 2)
    }

    func testARelayThatDoesNotAnswerIsUnavailableAndPinsNothing() async {
        rig.on("POST", "/admin-api/tee/attest", status: 504, json: #"{"error":"upstream timeout"}"#)
        let env = DelegatedFixture.environment()
        guard case .unavailable = await DelegatedAccounts.attemptRelayNodeKey(relay, env: env) else {
            return XCTFail("a relay that does not answer decided nothing")
        }
        XCTAssertNil(env.store.pinnedRelayNodeKey(relayURL: relay))
    }

    func testAQuoteThatDoesNotVerifyIsRefusedAndPinsNothing() async {
        DelegatedFixture.serveAttest(rig)
        var env = DelegatedFixture.environment()
        env.relayKeyVerifier = DcapRelayKeyVerifier()
        guard case .refused = await DelegatedAccounts.attemptRelayNodeKey(relay, env: env) else {
            return XCTFail("a mock quote from a hosted relay is an answer: no")
        }
        XCTAssertNil(env.store.pinnedRelayNodeKey(relayURL: relay))
    }

    func testLearnsTheKeyOnceTheRelayAnswersAgainAfterBackingOff() async {
        let hits = Counter()
        let key = try! Ed25519.publicKey(seed: DelegatedFixture.nodeSeed)
        rig.on("POST", "/admin-api/tee/attest") { seen in
            guard hits.increment() > 2 else { return CloudRig.stub(503, #"{"error":"down"}"#) }
            let nonce = (try? Hex.decode(seen.json?["nonce"]?.stringValue ?? "", label: "n", bytes: 32)) ?? Data()
            let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(key)
            return CloudRig.stub(
                200,
                #"{"data":{"quoteB64":"\#(quote.base64EncodedString())","boundPublicKey":"\#(Hex.encode(key))"}}"#)
        }
        let waits = DelegatedLog()
        var env = DelegatedFixture.environment()
        env.sleep = { waits.add("\($0)") }
        let learned = await DelegatedAccounts.learnRelayNodeKey(relay, env: env)
        XCTAssertEqual(learned, DelegatedFixture.nodeKey)
        XCTAssertEqual(waits.all, ["1.0", "2.0"])
        XCTAssertEqual(hits.count, 3)
    }

    func testKeepsRetryingEvery30SecondsUntilCancelled() async {
        rig.on("POST", "/admin-api/tee/attest", status: 503, json: #"{"error":"down"}"#)
        let waits = DelegatedLog()
        var env = DelegatedFixture.environment()
        env.sleep = { seconds in
            waits.add("\(seconds)")
            if waits.all.count == 7 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let url = relay
        let learned = await Task { await DelegatedAccounts.learnRelayNodeKey(url, env: env) }.value
        XCTAssertNil(learned)
        XCTAssertEqual(waits.all, ["1.0", "2.0", "5.0", "10.0", "30.0", "30.0", "30.0"])
        XCTAssertEqual(rig.requests("POST", "/admin-api/tee/attest").count, 7)
    }

    func testNeverRetriesARefusedQuoteIntoAcceptance() async {
        DelegatedFixture.serveAttest(rig)
        var env = DelegatedFixture.environment()
        env.relayKeyVerifier = DcapRelayKeyVerifier()
        let waits = DelegatedLog()
        env.sleep = { waits.add("\($0)") }
        let learned = await DelegatedAccounts.learnRelayNodeKey(relay, env: env)
        XCTAssertNil(learned)
        XCTAssertTrue(waits.all.isEmpty)
        XCTAssertEqual(rig.requests("POST", "/admin-api/tee/attest").count, 1)
    }

    // MARK: - The delegated client

    private func serveQuery(status: Int = 200, returns: String = #""queried""#) {
        rig.on("POST", "/admin-api/contexts/\(ctx)/query", status: status, json: #"{"data":{"returns":\#(returns)}}"#)
    }

    private func serveWarrant() {
        DelegatedFixture.serveDescribe(rig, ctx: ctx)
        rig.on("POST", "/admin-api/contexts/\(ctx)/intents", json: #"{"data":{"returns":"warranted","rootHash":"ff"}}"#)
    }

    private func pinnedEnvironment() -> DelegatedEnvironment {
        let env = DelegatedFixture.environment()
        env.store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.nodeKey)
        DelegatedFixture.serveLogin(rig)
        return env
    }

    func testThereIsNoClientWithoutARelay() throws {
        XCTAssertNil(try DelegatedAccounts.buildDelegatedClient(DelegatedFixture.session(relayUrl: nil)))
    }

    func testAViewIsReadWithTheSessionAndNoWarrantIsSpent() async throws {
        let env = pinnedEnvironment()
        serveQuery()
        serveWarrant()
        let client = try XCTUnwrap(try DelegatedAccounts.buildDelegatedClient(DelegatedFixture.session(), env: env))
        let value: String = try await client.rpc.execute(contextId: ctx, method: "get", argsJson: ["key": "k"])
        XCTAssertEqual(value, "queried")
        let query = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(ctx)/query").first)
        XCTAssertEqual(query.json?["method"], "get")
        XCTAssertEqual(query.json?["argsJson"], ["key": "k"])
        XCTAssertEqual(query.headers["authorization"], "Bearer relay-access")
        XCTAssertTrue(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").isEmpty)
        let read: ExecuteResult<String> = try await client.rpc.executeWithMetadata(
            contextId: ctx, method: "get", argsJson: [:])
        XCTAssertEqual(read, ExecuteResult(returns: "queried", transport: .relay), "a read reports no root hash")
    }

    func testAWriteRefusedAsAQueryGoesOutAsAWarrantAndIsNotAskedAgain() async throws {
        let env = pinnedEnvironment()
        serveQuery(status: 409, returns: "null")
        serveWarrant()
        let session = DelegatedFixture.session()
        let first = try XCTUnwrap(try DelegatedAccounts.buildDelegatedClient(session, env: env))
        let written: String = try await first.rpc.execute(contextId: ctx, method: "set", argsJson: [:])
        // A rebuilt client for the same relay keeps what was learned.
        let second = try XCTUnwrap(try DelegatedAccounts.buildDelegatedClient(session, contextId: ctx, env: env))
        let again: ExecuteResult<String> = try await second.rpc.executeWithMetadata(
            contextId: ctx, method: "set", argsJson: [:])
        XCTAssertEqual(written, "warranted")
        XCTAssertEqual(again.rootHash, "ff")
        XCTAssertEqual(rig.requests("POST", "/admin-api/contexts/\(ctx)/query").count, 1)
        XCTAssertEqual(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").count, 2)
    }

    func testAnyOtherFailureOfTheQueryFallsBackAndLearnsNothing() async throws {
        let env = pinnedEnvironment()
        serveQuery(status: 503, returns: "null")
        serveWarrant()
        let client = try XCTUnwrap(try DelegatedAccounts.buildDelegatedClient(DelegatedFixture.session(), env: env))
        let first: String = try await client.rpc.execute(contextId: ctx, method: "get", argsJson: [:])
        XCTAssertEqual(first, "warranted")
        serveQuery()
        let second: String = try await client.rpc.execute(contextId: ctx, method: "get", argsJson: [:])
        XCTAssertEqual(second, "queried")
        XCTAssertEqual(rig.requests("POST", "/admin-api/contexts/\(ctx)/query").count, 2)
    }

    func testWithNoRelayKeyEveryCallIsAWarrantAndEventsOpenNothing() async throws {
        serveWarrant()
        let client = try XCTUnwrap(
            try DelegatedAccounts.buildDelegatedClient(
                DelegatedFixture.session(), env: DelegatedFixture.environment()))
        let value: String = try await client.rpc.execute(contextId: ctx, method: "get", argsJson: [:])
        XCTAssertEqual(value, "warranted")
        XCTAssertTrue(rig.requests("POST", "/admin-api/contexts/\(ctx)/query").isEmpty)

        XCTAssertFalse(client.canSubscribe)
        let events = try client.events
        XCTAssertTrue(try client.events === events)
        events.connect()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.requests("GET", "/sse").isEmpty, "the inert stream reaches the network never")
        XCTAssertTrue(events.isRunning)
        await client.close()
        XCTAssertFalse(events.isRunning)
    }

    func testWithTheKeyPinnedEventsAreTheObserversOwnStream() throws {
        let env = pinnedEnvironment()
        let client = try XCTUnwrap(try DelegatedAccounts.buildDelegatedClient(DelegatedFixture.session(), env: env))
        XCTAssertTrue(client.canSubscribe)
        XCTAssertNoThrow(try client.ws, "a session-backed observer opens the socket too")
    }

    func testALoopbackRelayIsADevRigWhoseProofTheNodeTakes() throws {
        let client = try XCTUnwrap(
            try DelegatedAccounts.buildDelegatedClient(
                DelegatedFixture.session(relayUrl: "http://localhost:2428"), env: DelegatedFixture.environment()))
        XCTAssertTrue(client.canSubscribe)
        XCTAssertThrowsError(try client.ws, "a proof cannot open the socket")
    }

    // MARK: - Listing across relays

    func testListsContextsAndNamespacesOnEveryKnownRelayAndRecordsThem() async throws {
        let env = DelegatedFixture.environment()
        let session = DelegatedFixture.session()
        let other = "https://relay2.test"
        let down = "https://relay3.test"
        for url in [relay, other, down] {
            env.store.pinRelayNodeKey(relayURL: url, nodeKey: DelegatedFixture.nodeKey)
        }
        env.store.rememberRelay(account: session.account, relayURL: other, namespaceId: DelegatedFixture.rep("0a"))
        env.store.rememberRelay(account: session.account, relayURL: down, namespaceId: DelegatedFixture.rep("0b"))
        DelegatedFixture.serveLogin(rig)
        rig.on("GET", "/admin-api/contexts") { seen in
            switch seen.url.host {
            case "relay.test": return DelegatedAccountsTests.contexts(DelegatedFixture.rep("c1"))
            case "relay2.test": return DelegatedAccountsTests.contexts(DelegatedFixture.rep("c2"))
            default: return CloudRig.stub(500, #"{"error":"down"}"#)
            }
        }
        rig.on("GET", "/admin-api/namespaces") { seen in
            guard seen.url.host != "relay3.test" else { return CloudRig.stub(500, #"{"error":"down"}"#) }
            let listed = DelegatedAccountsTests.namespace(DelegatedFixture.rep("0a"))
            return CloudRig.stub(200, #"{"data":[\#(listed)]}"#)
        }

        let contexts = try await DelegatedAccounts.listDelegatedContexts(session, env: env)
        XCTAssertEqual(contexts.map(\.item.id), [DelegatedFixture.rep("c1"), DelegatedFixture.rep("c2")])
        XCTAssertEqual(contexts.map(\.relayUrl), [relay, other])
        XCTAssertEqual(
            DelegatedAccounts.relayForContext(session.account, contextId: DelegatedFixture.rep("c2"), store: env.store),
            other)

        let namespaces = try await DelegatedAccounts.listDelegatedNamespaces(session, env: env)
        XCTAssertEqual(namespaces.count, 1, "once each, however many relays list it")
        XCTAssertEqual(namespaces.first?.relayUrl, relay)
        let recorded = env.store.relayMap(account: session.account).namespaces[DelegatedFixture.rep("0a")]
        XCTAssertEqual(recorded, other, "a known relay stays")
    }

    /// 2026-10-21 (mero-js#299): a dead relay whose key was pinned passed the
    /// key check without the network, failed at the listing, and was skipped,
    /// so the account read as empty. Every relay failing is an error now.
    func testEveryRelayFailingThrowsInsteadOfListingAnEmptyAccount() async throws {
        let env = DelegatedFixture.environment()
        let session = DelegatedFixture.session()
        env.store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.nodeKey)
        DelegatedFixture.serveLogin(rig)
        rig.on("GET", "/admin-api/contexts") { _ in CloudRig.stub(502, #"{"error":"down"}"#) }
        rig.on("GET", "/admin-api/namespaces") { _ in CloudRig.stub(502, #"{"error":"down"}"#) }

        do {
            _ = try await DelegatedAccounts.listDelegatedNamespaces(session, env: env)
            XCTFail("expected RelaysUnavailableError")
        } catch let error as RelaysUnavailableError {
            XCTAssertEqual(error.failures.map(\.relayUrl), [relay])
            XCTAssertEqual(error.failures.first?.kind, .unavailable)
            XCTAssertFalse(error.refused)
        }
        do {
            _ = try await DelegatedAccounts.listDelegatedContexts(session, env: env)
            XCTFail("expected RelaysUnavailableError")
        } catch is RelaysUnavailableError {}
    }

    func testARelayThatAnswersNothingIsAnEmptyAccount() async throws {
        let env = DelegatedFixture.environment()
        let session = DelegatedFixture.session()
        env.store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.nodeKey)
        DelegatedFixture.serveLogin(rig)
        rig.on("GET", "/admin-api/namespaces") { _ in CloudRig.stub(200, #"{"data":[]}"#) }
        let namespaces = try await DelegatedAccounts.listDelegatedNamespaces(session, env: env)
        XCTAssertTrue(namespaces.isEmpty)
    }

    private static func contexts(_ id: String) -> MockURLProtocol.Stub {
        CloudRig.stub(
            200,
            #"{"data":{"contexts":[{"id":"\#(id)","applicationId":"app","contextStateHash":"h","dagHeads":[]}]}}"#)
    }

    private static func namespace(_ id: String) -> String {
        #"{"namespaceId":"\#(id)","appKey":"k","targetApplicationId":"a","createdAt":0,"memberCount":1,"#
            + #""contextCount":0,"subgroupCount":0}"#
    }
}
