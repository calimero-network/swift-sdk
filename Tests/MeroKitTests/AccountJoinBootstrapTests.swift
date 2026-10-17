import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `account/relay-from-invitation.test.ts`,
/// `join-with-node.test.ts`, `bootstrap-from-invitation.test.ts` and
/// `join-as-account.test.ts`.
final class AccountJoinBootstrapTests: XCTestCase {
    private let ns = DelegatedFixture.rep("aa")
    private let admitter = DelegatedFixture.rep("bb")
    private let relay = DelegatedFixture.relay
    private var rig: CloudRig!

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

    private func node(
        account: String? = nil, relayUrl: String? = "https://relay.test", admitUrl: String? = nil, fresh: Bool = true,
        canAdmit: Bool = true, canExecute: Bool = true, peerId: String = "p"
    ) -> CloudNamespaceNode {
        CloudNamespaceNode(
            peerId: peerId, account: account ?? admitter, relayUrl: relayUrl, admitUrl: admitUrl, status: "active",
            fresh: fresh, canAdmit: canAdmit, authorshipReady: canExecute, teeRole: "RelayTee", canExecute: canExecute)
    }

    private func resolve(
        _ nodes: [CloudNamespaceNode], admitters: [String]? = nil, servable: Bool = true
    ) async -> ResolveRelayResult {
        let ns = self.ns
        let routing = CloudNamespaceRouting(namespaceId: ns, nodes: nodes, servable: servable, writable: true)
        return await AccountJoin.resolveRelayFromInvitation(namespaceId: ns, admitters: admitters ?? [admitter]) { _ in
            routing
        }
    }

    private func invitation(admitters: [String] = [], addrs: [String] = []) -> SignedGroupOpenInvitation {
        var signed = SignedGroupOpenInvitation(
            invitation: GroupInvitationFromAdmin(
                inviterIdentity: Array(repeating: 1, count: 32), groupId: Array(repeating: 0xAA, count: 32),
                expirationTimestamp: 1_900_000_000, secretSalt: Array(repeating: 3, count: 32), invitedRole: 1,
                admitters: admitters),
            inviterSignature: "deadbeef")
        signed.admitterAddrs = addrs
        return signed
    }

    // MARK: - Relay resolution

    func testNormalisesAccountsIgnoringCaseAndA0xPrefix() {
        XCTAssertEqual(AccountJoin.normaliseAccount(" 0xAB "), "ab")
        XCTAssertNil(AccountJoin.normaliseAccount(""))
        XCTAssertNil(AccountJoin.normaliseAccount("0x"))
        XCTAssertNil(AccountJoin.normaliseAccount(nil))
    }

    func testReturnsTheInvitedAdmittingNode() async {
        let result = await resolve([node()])
        guard case .resolved(let relay) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(relay.relayUrl, "https://relay.test")
        XCTAssertEqual(relay.admitUrl, "https://relay.test/admin-api/namespaces/\(ns)/admit")
        XCTAssertEqual(relay.admitterAccount, admitter)
        XCTAssertEqual(relay.peerId, "p")
        XCTAssertTrue(relay.writable)
        XCTAssertFalse(relay.stale)
    }

    func testSeparatesNoFleetAssignmentFromNotInvitedFromALookupFailure() async {
        let none = await resolve([])
        XCTAssertEqual(none.failure?.step, .noNodes)
        let stranger = await resolve([node(account: DelegatedFixture.rep("cc"))])
        XCTAssertEqual(stranger.failure?.step, .notInvited)
        XCTAssertTrue(stranger.failure?.reason.contains("Ask for a fresh invitation") == true)
        let failed = await AccountJoin.resolveRelayFromInvitation(namespaceId: ns, admitters: []) { _ in
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(failed.failure?.step, .admittersLookup)
        XCTAssertTrue(failed.failure?.reason.contains("not the invitation") == true)
    }

    func testMatchesAdmittersThroughCaseAndPrefixAndTreatsNoneAsBroadcast() async {
        let prefixed = await resolve([node()], admitters: ["0x" + admitter.uppercased()])
        XCTAssertNotNil(prefixed.relay)
        let broadcast = await resolve([node(account: DelegatedFixture.rep("cc"))], admitters: [])
        XCTAssertNotNil(broadcast.relay, "an empty list is admission by broadcast, not nobody")
    }

    func testTriesANamedNodeOnAdvisoryDataAndSaysSo() async {
        let unservable = await resolve([node()], servable: false)
        XCTAssertEqual(unservable.relay?.stale, true)
        let cannotAdmit = await resolve([node(canAdmit: false)])
        XCTAssertEqual(cannotAdmit.relay?.stale, true)
        let lapsed = await resolve([node(fresh: false)])
        XCTAssertEqual(lapsed.relay?.stale, true)
    }

    func testRefusesAnAdmitterTheCloudHasNoAddressFor() async {
        let result = await resolve([node(relayUrl: nil)])
        XCTAssertEqual(result.failure?.step, .noRelayURL)
    }

    func testPrefersANodeThatCanAlsoAuthorButAdmitsThroughOneThatCannot() async {
        let both = await resolve([
            node(relayUrl: "https://a.test", canExecute: false, peerId: "a"),
            node(relayUrl: "https://b.test", canExecute: true, peerId: "b"),
        ])
        XCTAssertEqual(both.relay?.peerId, "b")
        let readOnly = await resolve([node(canExecute: false)])
        XCTAssertEqual(readOnly.relay?.writable, false)
    }

    func testUsesTheCloudsAdmitURLAndBuildsOneOnlyWhenNoneIsGiven() async {
        let given = await resolve([node(admitUrl: "https://ingress.test/admit/x")])
        XCTAssertEqual(given.relay?.admitUrl, "https://ingress.test/admit/x")
    }

    // MARK: - Joining with a node

    private func join(
        nodeURL: String = DelegatedFixture.relay, admitURL: String? = nil, credential: String? = nil
    ) async -> JoinWithNodeResult {
        let cb = DelegatedFixture.enrolled
        return await AccountJoin.joinWithNode(
            nodeURL: nodeURL, admitURL: admitURL, namespaceId: ns, invitation: invitation(), account: cb.account,
            credential: credential ?? cb.credential, keys: DelegatedFixture.keys, nonce: 1,
            session: MockURLProtocol.makeSession())
    }

    func testPostsTheSignedJoinToTheDocumentedRouteUnauthenticated() async throws {
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":true}}"#)
        let result = await join(nodeURL: relay + "/")
        XCTAssertEqual(result, .joined(published: true, relayUrl: relay))
        let sent = try XCTUnwrap(rig.requests("POST", "/admin-api/namespaces/\(ns)/admit").first)
        XCTAssertNil(sent.headers["authorization"])
        XCTAssertNil(sent.headers["x-calimero-proof"])
        XCTAssertEqual(sent.json?["signedOp"]?.stringValue?.prefix(2), "18")
        XCTAssertNotNil(sent.json?["invitation"]?["invitation"])
    }

    func testUsesTheCloudsReadyMadeAdmitURL() async {
        rig.on("POST", "/admit/x", json: #"{"data":{"published":true}}"#)
        let result = await join(admitURL: "https://ingress.test/admit/x")
        XCTAssertEqual(result, .joined(published: true, relayUrl: relay), "the session stays on the node")
    }

    func testReportsA2xxThatDidNotPublishAsNotPublished() async {
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":false}}"#)
        let result = await join()
        XCTAssertEqual(result, .joined(published: false, relayUrl: relay))
    }

    func testNamesTheAdmitStepAndKeepsTheStatus() async {
        for status in [400, 403, 409] {
            rig.on("POST", "/admin-api/namespaces/\(ns)/admit", status: status, json: #"{"error":"no"}"#)
            guard case .failed(let failure) = await join() else { return XCTFail("\(status) must fail") }
            XCTAssertEqual(failure.step, .admit)
            XCTAssertEqual(failure.status, status)
            XCTAssertTrue(failure.reason.contains("(\(status))"))
        }
    }

    func testDistinguishesAnUnreachableAdmitterFromARefusal() async {
        MockURLProtocol.reset()
        guard case .failed(let failure) = await join() else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.step, .admit)
        XCTAssertNil(failure.status)
        XCTAssertTrue(failure.reason.contains("could not be reached"))
    }

    func testFailsAtTheSigningStepHavingSentNothing() async {
        guard case .failed(let failure) = await join(credential: "not hex") else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(failure.step, .sign)
        XCTAssertTrue(rig.seen.isEmpty)
    }

    // MARK: - Bootstrap

    private func cloud() -> CloudClient {
        CloudClient(baseURL: DelegatedFixture.cloud, session: MockURLProtocol.makeSession())
    }

    private func serveRouting(_ admitters: String) {
        rig.on("GET", "/api/cloud/namespaces/\(ns)/challenge", json: #"{"nonce":"n"}"#)
        rig.on(
            "GET", "/api/cloud/namespaces/\(ns)/admitters", json: #"{"servable":true,"admitters":[\#(admitters)]}"#)
    }

    private var routedRelay: String {
        #"{"peer_id":"p","account":"\#(admitter)","relay_url":"\#(relay)","status":"active","fresh":true,"#
            + #""can_admit":true,"authorship_ready":true,"can_execute":true}"#
    }

    private func bootstrap(
        nodeURL: String? = nil, invitation: SignedGroupOpenInvitation? = nil
    ) async -> BootstrapResult {
        let cb = DelegatedFixture.enrolled
        return await AccountJoin.bootstrapFromInvitation(
            namespaceId: ns, invitation: invitation ?? self.invitation(admitters: [admitter]), account: cb.account,
            credential: cb.credential, keys: DelegatedFixture.keys, nonce: 1, nodeURL: nodeURL, cloud: cloud(),
            session: MockURLProtocol.makeSession())
    }

    func testResolvesANodeFromTheCloudThenJoinsThroughIt() async {
        serveRouting(routedRelay)
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":true}}"#)
        let result = await bootstrap()
        XCTAssertEqual(result.outcome?.relayUrl, relay)
        XCTAssertEqual(result.outcome?.relay?.admitterAccount, admitter)
        XCTAssertEqual(result.outcome?.published, true)
    }

    func testSkipsTheCloudLookupWhenANodeURLIsGiven() async {
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":true}}"#)
        let result = await bootstrap(nodeURL: "https://operator.test/")
        XCTAssertEqual(result.outcome?.relayUrl, "https://operator.test")
        XCTAssertNil(result.outcome?.relay)
        XCTAssertTrue(rig.requests("GET", "/api/cloud/namespaces/\(ns)/admitters").isEmpty)
    }

    func testPassesAResolutionOrJoinFailureStraightThrough() async {
        serveRouting("")
        let unrouted = await bootstrap()
        XCTAssertEqual(unrouted.failure?.step, .noNodes)
        serveRouting(routedRelay)
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", status: 403, json: #"{"error":"not an admitter"}"#)
        let refused = await bootstrap()
        XCTAssertEqual(refused.failure?.step, .admit)
        XCTAssertEqual(refused.failure?.status, 403)
        XCTAssertThrowsError(try refused.get()) { XCTAssertEqual(($0 as? BootstrapFailure)?.status, 403) }
    }

    func testNeverJoinsThroughAnAddressTheInvitationCarries() async {
        serveRouting("")
        let result = await bootstrap(invitation: invitation(admitters: [admitter], addrs: ["https://evil.test"]))
        XCTAssertEqual(result.failure?.step, .noNodes)
        XCTAssertFalse(rig.seen.contains { $0.url.host == "evil.test" })
    }

    // MARK: - Joining as an account

    private func environment() -> DelegatedEnvironment { DelegatedFixture.environment() }

    func testJoinsThroughTheInvitedRelayRemembersItAndMovesTheSessionOntoIt() async throws {
        serveRouting(routedRelay)
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":true}}"#)
        let env = environment()
        let joined = DelegatedSessionBox()
        let before = DelegatedFixture.session(relayUrl: nil)
        let namespaceId = try await DelegatedAccounts.joinAsAccount(
            before, namespaceId: ns, invitation: invitation(admitters: [admitter]), env: env
        ) { joined.set($0) }
        XCTAssertEqual(namespaceId, ns)
        XCTAssertEqual(joined.value?.relayUrl, relay)
        XCTAssertEqual(env.store.relayMap(account: before.account).namespaces[ns], relay)
    }

    func testARefusedJoinThrowsItsStepAndStatusAndMovesNothing() async {
        serveRouting(routedRelay)
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", status: 403, json: #"{"error":"no"}"#)
        let env = environment()
        let joined = DelegatedSessionBox()
        do {
            try await DelegatedAccounts.joinAsAccount(
                DelegatedFixture.session(), namespaceId: ns, invitation: invitation(admitters: [admitter]), env: env
            ) { joined.set($0) }
            XCTFail("a refused join must throw")
        } catch {
            XCTAssertEqual((error as? BootstrapFailure)?.step, .admit)
            XCTAssertEqual((error as? BootstrapFailure)?.status, 403)
        }
        XCTAssertNil(joined.value)
        XCTAssertTrue(env.store.relayMap(account: DelegatedFixture.session().account).namespaces.isEmpty)
    }

    func testKeepsTheExecutorOnTheSameRelayAndDropsItOnAnother() async throws {
        serveRouting(routedRelay)
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":true}}"#)
        let joined = DelegatedSessionBox()
        let executor = DelegatedFixture.rep("33")
        try await DelegatedAccounts.joinAsAccount(
            DelegatedFixture.session(executorAccount: executor), namespaceId: ns,
            invitation: invitation(admitters: [admitter]), env: environment()
        ) { joined.set($0) }
        XCTAssertEqual(joined.value?.executorAccount, executor)
        try await DelegatedAccounts.joinAsAccount(
            DelegatedFixture.session(relayUrl: "https://other.test", executorAccount: executor), namespaceId: ns,
            invitation: invitation(admitters: [admitter]), env: environment()
        ) { joined.set($0) }
        XCTAssertNil(joined.value?.executorAccount)
    }

    func testCloudSignInJoinNamesTheMissingCredentialStep() async {
        let signIn = CloudSignIn(
            keyStore: .memory(DelegatedFixture.keys), sessionStore: .memory(),
            urlSession: MockURLProtocol.makeSession(), delegatedStore: .memory())
        do {
            _ = try await signIn.join(namespaceId: ns, invitation: invitation())
            XCTFail("nobody is signed in")
        } catch {
            XCTAssertEqual((error as? BootstrapFailure)?.step, .noCredential)
        }
    }
}

/// The session a join handed over, read back by the test.
final class DelegatedSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DelegatedSession?

    func set(_ session: DelegatedSession) {
        lock.lock()
        stored = session
        lock.unlock()
    }

    var value: DelegatedSession? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
