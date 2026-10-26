import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `account/create-context.test.ts` and
/// `create-context.found.test.ts`: contexts, governance and founding through
/// the relay that serves the namespace.
final class DelegatedGovernanceTests: XCTestCase {
    private let ns = DelegatedFixture.rep("01")
    private let relay = DelegatedFixture.relay
    private let executor = DelegatedFixture.rep("33")
    private var log: DelegatedLog!
    /// What `POST /api/cloud/accounts/…/enable-ha` answers.
    private var haAnswer: MockURLProtocol.Stub!
    /// Whether the relay's governance POST reports a TEE founding.
    private var teeEnabled = true

    override func setUp() {
        super.setUp()
        log = DelegatedLog()
        haAnswer = CloudRig.stub(200, #"{"status":"enabled"}"#)
        teeEnabled = true
        install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        log = nil
        super.tearDown()
    }

    /// A relay answering every governance and creation route, the relay's
    /// mock attestation, and the cloud's enable-ha.
    private func install(discoveryKey: String? = nil) {
        let log = self.log!
        let executor = self.executor
        let haAnswer = self.haAnswer!
        let tee = teeEnabled
        let nodeKey = try! Ed25519.publicKey(seed: DelegatedFixture.nodeSeed)
        let describedKey = discoveryKey ?? Hex.encode(nodeKey)
        MockURLProtocol.setHandler { req in
            let path = req.url!.path
            let method = req.httpMethod ?? "GET"
            let body = try? MeroJSON.decode(JSONValue.self, from: FakeNode.body(req))
            log.add("\(method) \(req.url!.host ?? "")\(path)")
            if path == "/admin-api/tee/attest" {
                let nonce = (try? Hex.decode(body?["nonce"]?.stringValue ?? "", label: "n", bytes: 32)) ?? Data()
                let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(nodeKey)
                let quoteB64 = quote.base64EncodedString()
                let bound = Hex.encode(nodeKey)
                return CloudRig.stub(200, #"{"data":{"quoteB64":"\#(quoteB64)","boundPublicKey":"\#(bound)"}}"#)
            }
            let group = String(path.split(separator: "/").dropFirst(2).first ?? "")
            if path.hasSuffix("/governance-intents") || path.hasSuffix("/context-intents") {
                if method == "GET" {
                    return CloudRig.stub(
                        200,
                        #"{"data":{"executorAccount":"\#(executor)","executorKey":"\#(describedKey)","#
                            + #""groupId":"\#(group)","canActOnBehalf":true,"canCreateOnBehalf":true}}"#)
                }
                if path.hasSuffix("/context-intents") {
                    let context = DelegatedFixture.rep("c0")
                    return CloudRig.stub(
                        200, #"{"data":{"contextId":"\#(context)","groupId":"\#(group)","memberPublicKey":"m"}}"#)
                }
                // A subgroup's create names its derived id right after the tag.
                let op = body?["op"]?.stringValue ?? ""
                let created = op.hasPrefix("00") && op.count >= 66 ? String(op.dropFirst(2).prefix(64)) : group
                return CloudRig.stub(200, #"{"data":{"groupId":"\#(created)","teeEnabled":\#(tee)}}"#)
            }
            if path.hasSuffix("/enable-ha") { return haAnswer }
            return CloudRig.stub(404, #"{"error":"no route"}"#)
        }
    }

    private func environment() -> DelegatedEnvironment {
        DelegatedFixture.environment()
    }

    private var posts: [String] { log.all.filter { $0.hasPrefix("POST") } }

    // MARK: - Contexts

    func testCreatesAContextThroughTheNamespacesRelayAndRemembersBoth() async throws {
        let env = environment()
        let session = DelegatedFixture.session()
        env.store.rememberRelay(account: session.account, relayURL: "https://relay2.test", namespaceId: ns)
        let created = try await DelegatedAccounts.createDelegatedContext(
            session,
            CreateDelegatedContextRequest(
                namespaceId: ns, applicationId: DelegatedFixture.rep("44"), serviceName: "registry",
                contextSeed: DelegatedFixture.rep("ff"), initializationParams: Array(#"{"a":1}"#.utf8).map { Int($0) },
                name: "Registry"),
            env: env)
        XCTAssertEqual(created.contextId, DelegatedFixture.rep("c0"))
        XCTAssertEqual(posts, ["POST relay2.test/admin-api/groups/\(ns)/context-intents"])
        let map = env.store.relayMap(account: session.account)
        XCTAssertEqual(map.contexts[created.contextId], "https://relay2.test")
        XCTAssertEqual(env.nonces.next(relay: "https://relay2.test"), 1, "the creation nonce 0 is spent, and only it")
    }

    func testInitArgumentsAreTheBytesAsJson() throws {
        XCTAssertEqual(try DelegatedAccounts.initArgs(nil), [:])
        XCTAssertEqual(try DelegatedAccounts.initArgs(Array(#"{"a":1}"#.utf8).map { Int($0) }), ["a": 1])
        XCTAssertThrowsError(try DelegatedAccounts.initArgs([300]))
    }

    func testNothingIsSentWithoutARelayForTheNamespace() async {
        do {
            _ = try await DelegatedAccounts.createDelegatedContext(
                DelegatedFixture.session(relayUrl: nil),
                CreateDelegatedContextRequest(namespaceId: ns, applicationId: DelegatedFixture.rep("44")),
                env: environment())
            XCTFail("no relay, nowhere to send it")
        } catch {
            XCTAssertEqual(classifyError(error).kind, .unavailable)
        }
        XCTAssertTrue(log.all.isEmpty)
    }

    func testAPrivateContextIsARestrictedSubgroupItsMembersAndTheContext() async throws {
        let env = environment()
        let session = DelegatedFixture.session()
        let members = [DelegatedFixture.rep("bb"), DelegatedFixture.rep("cc")]
        let made = try await DelegatedAccounts.createDelegatedPrivateContext(
            session, CreateDelegatedContextRequest(namespaceId: ns, applicationId: DelegatedFixture.rep("44")),
            members: members, env: env)
        let sub = made.groupId
        XCTAssertNotEqual(sub, ns)
        XCTAssertEqual(
            posts,
            [
                "POST relay.test/admin-api/groups/\(ns)/governance-intents",
                "POST relay.test/admin-api/groups/\(sub)/governance-intents",
                "POST relay.test/admin-api/groups/\(sub)/governance-intents",
                "POST relay.test/admin-api/groups/\(sub)/context-intents",
            ])
        XCTAssertEqual(DelegatedAccounts.namespaceOfGroup(session, groupId: sub, store: env.store), ns)
    }

    // MARK: - Governance

    func testAGroupOpGoesToTheGroupAndARootOpToItsNamespace() async throws {
        let env = environment()
        let session = DelegatedFixture.session()
        let sub = DelegatedFixture.rep("02")
        env.store.rememberRelay(account: session.account, relayURL: relay, namespaceId: ns)
        env.store.rememberGroupNamespace(account: session.account, groupId: sub, namespaceId: ns)
        try await DelegatedAccounts.governGroup(
            session, groupId: sub, op: GovernanceOps.groupMetadataSet(name: "general"), env: env)
        try await DelegatedAccounts.governRoot(session, groupId: sub, op: try GovernanceOps.groupDeleted(sub), env: env)
        XCTAssertEqual(
            posts,
            [
                "POST relay.test/admin-api/groups/\(sub)/governance-intents",
                "POST relay.test/admin-api/groups/\(ns)/governance-intents",
            ])
    }

    func testAGroupWhoseNamespaceIsUnknownIsRefusedUnsent() async {
        do {
            try await DelegatedAccounts.governGroup(
                DelegatedFixture.session(), groupId: DelegatedFixture.rep("09"),
                op: GovernanceOps.groupMetadataSet(name: "x"), env: environment())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is not known to this account"))
        }
        XCTAssertTrue(log.all.isEmpty)
    }

    // MARK: - Founding

    private func found(
        _ session: DelegatedSession, env: DelegatedEnvironment, application: Bool = false
    ) async throws -> FoundedDelegatedNamespace {
        let app = FoundingApplication(
            applicationId: DelegatedFixture.rep("44"), package: "com.calimero.chat", version: "1")
        return try await DelegatedAccounts.foundDelegatedNamespace(
            session, defaultCapabilities: 231, application: application ? app : nil, env: env)
    }

    func testFoundsWithTheSessionsExecutorAttestingTheRelayEvenWithItsKeyPinned() async throws {
        let env = environment()
        env.store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.rep("ab"))
        let session = DelegatedFixture.session(executorAccount: executor)
        let founded = try await found(session, env: env, application: true)
        let attests = log.all.filter { $0.hasSuffix("/tee/attest") }
        XCTAssertEqual(attests.count, 1, "attested now, not trusted from the pin")
        XCTAssertEqual(
            founded.namespaceId, try GovernanceOps.foundedNamespaceId(founder: session.account, salt: founded.salt))
        XCTAssertEqual(env.store.relayMap(account: session.account).namespaces[founded.namespaceId], relay)
        XCTAssertTrue(founded.haEnabled, founded.haError ?? "")
        XCTAssertTrue(log.all.contains { $0.hasSuffix("/namespaces/\(founded.namespaceId)/enable-ha") })
    }

    func testLearnsTheExecutorFromANamespaceItIsInCheckedAgainstTheAttestedKey() async throws {
        let env = environment()
        let session = DelegatedFixture.session()
        env.store.rememberRelay(account: session.account, relayURL: relay, namespaceId: ns)
        _ = try await found(session, env: env)
        XCTAssertTrue(log.all.contains("GET relay.test/admin-api/groups/\(ns)/governance-intents"))

        install(discoveryKey: DelegatedFixture.rep("ee"))
        do {
            _ = try await found(session, env: env)
            XCTFail("a discovery naming another key than the node's must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refusing to found through it"))
        }
    }

    func testTellsABrandNewAccountWithNoKnownExecutorHowToGetOne() async {
        do {
            _ = try await found(DelegatedFixture.session(), env: environment())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("join a namespace on it first"))
        }
    }

    func testRefusesToFoundThroughARelayWhoseAttestationIsRefused() async {
        var env = environment()
        env.relayKeyVerifier = DcapRelayKeyVerifier()
        env.store.pinRelayNodeKey(relayURL: relay, nodeKey: DelegatedFixture.nodeKey)
        do {
            _ = try await found(DelegatedFixture.session(executorAccount: executor), env: env)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("founding through it is not possible"))
        }
        XCTAssertTrue(posts.filter { $0.contains("governance-intents") }.isEmpty, "nothing founded")
    }

    func testDoesNotAskForHaWhenTheRelayDidNotAttestTheFounding() async throws {
        teeEnabled = false
        install()
        let founded = try await found(DelegatedFixture.session(executorAccount: executor), env: environment())
        XCTAssertFalse(founded.haEnabled)
        XCTAssertTrue(founded.haError?.contains("did not attest the founding") == true)
        XCTAssertFalse(log.all.contains { $0.hasSuffix("/enable-ha") })
    }

    func testStillFoundsWhenTheCloudRefusesHaAndSaysWhy() async throws {
        haAnswer = CloudRig.stub(409, #"{"error":"account_not_linked"}"#)
        install()
        let session = DelegatedFixture.session(executorAccount: executor)
        let unlinked = try await found(session, env: environment())
        XCTAssertEqual(unlinked.haError, CloudClient.haAccountNotLinkedMessage)

        let waiting = DelegatedFixture.rep("ab")
        haAnswer = CloudRig.stub(409, #"{"detail":{"error":"ha_request_pending","namespace_id":"\#(waiting)"}}"#)
        install()
        let pending = try await found(session, env: environment())
        XCTAssertEqual(
            pending.haError, "\(CloudClient.haRefusalMessages["ha_request_pending"] ?? "") (waiting: \(waiting))")

        haAnswer = CloudRig.stub(500, #"{"error":"boom"}"#)
        install()
        let failed = try await found(session, env: environment())
        XCTAssertFalse(failed.haEnabled)
        XCTAssertNotNil(failed.haError)
    }

    func testTheLatestPublishedVersionSkipsYankedOnes() async throws {
        MockURLProtocol.setHandler { _ in
            CloudRig.stub(
                200,
                #"[{"package":"p","appVersion":"1.2.0"},{"package":"p","appVersion":"1.10.0","yanked":true},"#
                    + #"{"package":"p","appVersion":"1.9.0"}]"#)
        }
        let version = try await DelegatedAccounts.latestPublishedVersion(
            registryURL: "https://registry.test", package: "p", session: MockURLProtocol.makeSession())
        XCTAssertEqual(version, "1.9.0")
    }
}
