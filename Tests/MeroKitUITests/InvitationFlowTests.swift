import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// A signed invitation good enough to pass through the view models.
func invitationFlowInvitation() -> SignedGroupOpenInvitation {
    SignedGroupOpenInvitation(
        invitation: GroupInvitationFromAdmin(
            inviterIdentity: [], groupId: [], expirationTimestamp: 0, secretSalt: [], invitedRole: 1, admitters: []),
        inviterSignature: "sig")
}

/// A codec that reads `NS:<id>[:<team>]` tokens.
func invitationFlowParse(_ token: String, _ params: [String: String]) -> ParsedInvitation? {
    let parts = token.split(separator: ":").map(String.init)
    guard parts.count >= 2, parts[0] == "NS" else { return nil }
    return ParsedInvitation(
        namespaceId: parts[1], invitation: invitationFlowInvitation(), teamName: parts.count > 2 ? parts[2] : nil,
        extra: params)
}

/// Ports of mero-react `invitations/capture.test.ts` and `invitation-raw.test.ts`.
@MainActor
final class InvitationCaptureTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = appLayerDefaults()
    }

    /// One cold open of an app carrying `token`: a new capture over the same
    /// storage, opened with the link.
    private func openWith(_ token: String, appKey: String? = nil) -> [CapturedInvitation] {
        let capture = InvitationCapture(defaults: defaults)
        if let appKey { capture.prime(appKey: appKey) }
        capture.handle(URL(string: "myapp://open?invitation=\(token)")!)
        var seen: [CapturedInvitation] = []
        _ = capture.onInvitation { seen.append($0) }
        return seen
    }

    func testAnInvitationOnTheAppsURLIsCaptured() {
        let seen = openWith("TOKEN123")
        XCTAssertEqual(seen.map(\.token), ["TOKEN123"])
    }

    func testADeeperPageWithTheParameterIsStillOurs() {
        let capture = InvitationCapture(defaults: defaults)
        capture.handle(URL(string: "https://app.example/teams/t1/projects?invitation=DEEP")!)
        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        XCTAssertEqual(seen, ["DEEP"])
    }

    func testALateListenerGetsTheReplay() {
        let capture = InvitationCapture(defaults: defaults)
        capture.prime()
        capture.handle(URL(string: "myapp://open?invitation=LATE")!)
        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        XCTAssertEqual(seen, ["LATE"])
    }

    func testNothingIsDeliveredWithoutAnInvitation() {
        let capture = InvitationCapture(defaults: defaults)
        capture.handle(URL(string: "myapp://teams")!)
        capture.handle(URL(string: "https://app.example/teams")!)
        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        XCTAssertEqual(seen, [])
        XCTAssertNil(capture.peek())
    }

    func testAnUnackedInvitationReplaysOnTheNextLaunch() {
        _ = openWith("AGAIN")
        let relaunch = InvitationCapture(defaults: defaults)
        var seen: [String] = []
        _ = relaunch.onInvitation { seen.append($0.token) }
        XCTAssertEqual(seen, ["AGAIN"], "persisted until acked")
    }

    func testAutoJoinStopsAfterTheCap() {
        for _ in 0..<maxAutoJoinAttempts {
            XCTAssertEqual(openWith("LOOPY").first?.autoJoin, true)
        }
        let exhausted = openWith("LOOPY").first
        XCTAssertEqual(exhausted?.autoJoin, false)
        XCTAssertEqual(exhausted?.token, "LOOPY", "still handed over, for a one-tap retry")
    }

    func testAttemptsArePerInvitation() {
        for _ in 0..<maxAutoJoinAttempts { _ = openWith("ONE") }
        XCTAssertEqual(openWith("ONE").first?.autoJoin, false)
        XCTAssertEqual(openWith("TWO").first?.autoJoin, true)
    }

    func testEachAppKeepsItsOwnLedger() {
        for _ in 0..<maxAutoJoinAttempts { _ = openWith("SHARED", appKey: "app-a") }
        XCTAssertEqual(openWith("SHARED", appKey: "app-a").first?.autoJoin, false)
        XCTAssertEqual(openWith("SHARED", appKey: "app-b").first?.autoJoin, true)
    }

    func testAnAckForgetsTheAttemptsAndStopsTheReplay() {
        _ = openWith("USED")
        openWith("USED").first?.resolve()
        let capture = InvitationCapture(defaults: defaults)
        XCTAssertEqual(capture.attempts(for: "USED"), 0)
        var replayed: [String] = []
        _ = capture.onInvitation { replayed.append($0.token) }
        XCTAssertEqual(replayed, [], "acked: dropped from the store")
        XCTAssertEqual(openWith("USED").first?.autoJoin, true)
    }

    func testALinkForThisAppJoinsAndOneForAnotherIsDropped() {
        let capture = InvitationCapture(defaults: defaults)
        capture.prime(appKey: "app", slugs: ["com.calimero.docs"])
        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        XCTAssertTrue(capture.capture(raw: "calimero://com.calimero.docs/join?invitation=WARM"))
        XCTAssertFalse(capture.capture(raw: "calimero://com.calimero.chat/join?invitation=FOREIGN"))
        let foreignLink = "https://links.calimero.network/com.calimero.chat/join?invitation=FOREIGN2"
        XCTAssertFalse(capture.capture(raw: foreignLink))
        XCTAssertEqual(seen, ["WARM"])

        let relaunch = InvitationCapture(defaults: defaults)
        relaunch.prime(appKey: "app", slugs: ["com.calimero.docs"])
        var replayed: [String] = []
        _ = relaunch.onInvitation { replayed.append($0.token) }
        XCTAssertEqual(replayed, ["WARM"], "the foreign ones were acked, not kept")
    }

    func testAWatcherSeesItWithoutTakingItFromTheRedeemer() {
        let capture = InvitationCapture(defaults: defaults)
        var changes = 0
        let off = capture.subscribe { changes += 1 }
        XCTAssertNil(capture.peek())
        capture.handle(URL(string: "myapp://open?invitation=WATCHED")!)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(capture.peek()?.token, "WATCHED")

        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        XCTAssertEqual(seen, ["WATCHED"], "watching consumed nothing")

        let before = changes
        capture.peek()?.resolve()
        XCTAssertEqual(changes, before + 1)
        XCTAssertNil(capture.peek())
        off()
    }

    func testAnInvitationAckedBeforeAnyoneSubscribedIsNotReplayed() {
        let capture = InvitationCapture(defaults: defaults)
        capture.handle(URL(string: "myapp://open?invitation=DECLINED")!)
        capture.peek()?.resolve()
        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        XCTAssertEqual(seen, [])
    }

    func testTheSameLinkFromTwoSourcesIsHandledOnce() {
        let capture = InvitationCapture(defaults: defaults)
        var seen: [String] = []
        _ = capture.onInvitation { seen.append($0.token) }
        capture.capture(raw: "calimero://app/join?invitation=ONCE")
        capture.capture(raw: "calimero://app/join?invitation=ONCE")
        XCTAssertEqual(seen, ["ONCE"])
    }

    func testTheShareableLinkShape() {
        XCTAssertEqual(
            buildInviteLink(slug: "com.calimero.docs", token: "a+b/c"),
            "https://links.calimero.network/com.calimero.docs/join?invitation=a%2Bb%2Fc")
        let link = buildInviteLink(slug: "com.calimero.docs", token: "T", extra: ["name": "Q3 plan", "id": nil])
        XCTAssertEqual(link, "https://links.calimero.network/com.calimero.docs/join?invitation=T&name=Q3+plan")
        XCTAssertEqual(
            buildInviteLink(slug: "pkg", token: "T", host: "calimero:/"), "calimero://pkg/join?invitation=T")
    }

    func testInvitationFromRaw() {
        XCTAssertEqual(invitationFromRaw("https://links.calimero.network/app/join?invitation=abc"), "abc")
        XCTAssertEqual(invitationFromRaw("calimero://mero-sign/join?invitation=xyz"), "xyz")
        XCTAssertEqual(invitationFromRaw("  4WoJA5rDhe5WQVVyZF  "), "4WoJA5rDhe5WQVVyZF")
        XCTAssertNil(invitationFromRaw("http://localhost:5390/teams"))
        XCTAssertNil(invitationFromRaw("https://app.example/agreements/1"))
        XCTAssertNil(invitationFromRaw("/teams"))
        XCTAssertNil(invitationFromRaw("https://app.example/?tab=1"))
    }

    func testURLWithoutInvitation() {
        XCTAssertEqual(urlWithoutInvitation("https://a.example/?invitation=X&keep=1"), "https://a.example/?keep=1")
        XCTAssertEqual(urlWithoutInvitation("https://a.example/x"), "https://a.example/x")
    }

    func testTheIntentNonceIsMeroPlatformsFNV1a() {
        XCTAssertEqual(PendingIntentStore.nonce(""), "811c9dc5")
        XCTAssertEqual(PendingIntentStore.nonce("a"), "e40c292c")
    }
}

/// Ports of mero-react `invitations/useInviteRedemption.test.tsx`.
@MainActor
final class InviteRedemptionTests: XCTestCase {
    private var capture: InvitationCapture!
    private var justJoined: JustJoinedNamespaces!

    override func setUp() {
        super.setUp()
        capture = InvitationCapture(defaults: appLayerDefaults())
        justJoined = JustJoinedNamespaces()
    }

    private func open(_ token: String) {
        capture.handle(URL(string: "myapp://open?invitation=\(token)&via=link")!)
    }

    private func redemption(
        confirm: Bool = false, enabled: Bool = true, redeem: InviteRedemption.Redeem? = nil,
        onJoined: ((String, String?) -> Void)? = nil
    ) -> InviteRedemption {
        let standard: InviteRedemption.Redeem = { parsed in
            RedeemOutcome.joined(namespaceId: parsed.namespaceId, teamName: parsed.teamName)
        }
        return InviteRedemption(
            parse: invitationFlowParse, redeem: redeem ?? standard, confirm: confirm, onJoined: onJoined,
            enabled: enabled, capture: capture, justJoined: justJoined)
    }

    func testJoiningThenJoinedReportsTheNamespaceOnce() async {
        var joined: [String] = []
        open("NS:ns1:Design")
        let model = redemption(onJoined: { ns, _ in joined.append(ns) })
        let done = await appLayerEventually { model.state == .joined(namespaceId: "ns1", teamName: "Design") }
        XCTAssertTrue(done)
        XCTAssertEqual(joined, ["ns1"])
        XCTAssertTrue(justJoined.contains("ns1"), "marked for the sync gate")
        XCTAssertNil(capture.peek(), "acked on the outcome")
    }

    func testTheAppsOwnFailureIsReportedAndKeptWhenRetryable() async {
        open("NS:ns1")
        let model = redemption(redeem: { _ in
            .failed(namespaceId: "ns1", message: "nobody online", reason: .noOneOnline, retryable: true)
        })
        let failed = await appLayerEventually { model.state.stage == "failed" }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.state, .failed(message: "nobody online", reason: .noOneOnline, retryable: true))
        XCTAssertNotNil(capture.peek(), "retryable: kept for the next launch")
        XCTAssertEqual(model.token, "NS:ns1")
    }

    func testAlreadyMemberWhenTheRequestFailedButTheJoinLanded() async {
        open("NS:ns1")
        let redeemer = InviteRedeemer(
            join: { _, _ in throw MeroError.network("proxy timed out") }, memberships: { ["ns1"] })
        let model = InviteRedemption(
            parse: invitationFlowParse, redeemer: redeemer, confirm: false, capture: capture, justJoined: justJoined)
        let done = await appLayerEventually { model.state == .alreadyMember(namespaceId: "ns1", teamName: nil) }
        XCTAssertTrue(done)
    }

    func testAnUnreadableInvitationIsAckedNotReplayed() async {
        open("garbage")
        let model = redemption()
        let unreadable = InviteState.failed(
            message: "That invitation could not be read.", reason: .invalid, retryable: false)
        XCTAssertEqual(model.state, unreadable)
        XCTAssertNil(capture.peek())
    }

    func testNothingJoinsUntilEnabled() async {
        open("NS:ns1")
        let model = redemption(enabled: false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.state, .idle)
        model.enable()
        let done = await appLayerEventually { model.state.stage == "joined" }
        XCTAssertTrue(done)
    }

    func testRetryJoinsPastTheCapWithoutAskingAgain() async {
        var calls = 0
        open("NS:ns1")
        let model = redemption(redeem: { _ in
            calls += 1
            return .failed(namespaceId: "ns1", message: "down", reason: .nodeUnreachable, retryable: true)
        })
        _ = await appLayerEventually { model.state.stage == "failed" }
        model.retry()
        let again = await appLayerEventually { calls == 2 }
        XCTAssertTrue(again)
    }

    func testTheCodecGetsEveryParameterTheLinkCarried() async {
        open("NS:ns1")
        let model = redemption(confirm: true)
        XCTAssertEqual(model.parsed?.extra["via"], "link")
        XCTAssertEqual(model.parsed?.extra["invitation"], "NS:ns1")
    }

    func testConfirmModeAsksAndJoinsOnAccept() async {
        open("NS:ns1:Design")
        let model = redemption(confirm: true)
        XCTAssertEqual(model.state, .awaitingConfirmation(teamName: "Design"))
        model.accept()
        let done = await appLayerEventually { model.state.stage == "joined" }
        XCTAssertTrue(done)
    }

    func testDeclineAcksSoThePromptDoesNotReturn() {
        open("NS:ns1")
        let model = redemption(confirm: true)
        model.decline()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(capture.peek())
    }

    func testConfirmModeStillAsksOnceTheAttemptsAreSpent() {
        let defaults = appLayerDefaults()
        for _ in 0...maxAutoJoinAttempts {
            let run = InvitationCapture(defaults: defaults)
            run.handle(URL(string: "myapp://open?invitation=NS:ns1")!)
            capture = run
        }
        XCTAssertEqual(capture.peek()?.autoJoin, false)
        let model = redemption(confirm: true)
        XCTAssertEqual(model.state.stage, "awaiting-confirmation")
    }

    func testDescribeInviteFailure() {
        XCTAssertEqual(describeInviteFailure(.expired), "This invitation has expired. Ask for a new link.")
        XCTAssertEqual(
            describeInviteFailure(.refused, noun: "vault"),
            "You can't join this vault with this invitation. Ask an admin to invite you again.")
        XCTAssertNil(describeInviteFailure(.unknown))
    }

    func testIsFinalInvitationError() {
        XCTAssertTrue(isFinalInvitationError("HTTP 400: invitation expired"))
        XCTAssertTrue(isFinalInvitationError("Invalid Signature on the invitation"))
        XCTAssertTrue(isFinalInvitationError("already a member of this namespace"))
        XCTAssertFalse(isFinalInvitationError(nil))
        XCTAssertFalse(isFinalInvitationError("HTTP 504: could not reach any member"))
        XCTAssertFalse(isFinalInvitationError("502 invalid response from upstream"))
    }

    func testIsReturningFromWallet() {
        XCTAssertFalse(isReturningFromWallet(URL(string: "myapp://enrol")))
        XCTAssertTrue(isReturningFromWallet(URL(string: "myapp://enrol#error=cancelled")))
        XCTAssertTrue(isReturningFromWallet(URL(string: "myapp://enrol#credential=c&account=a&device=d")))
        XCTAssertFalse(isReturningFromWallet(URL(string: "myapp://enrol#credential=c&account=a")))
    }
}

/// Ports of mero-react `invitations/useJoinSync.test.tsx`.
@MainActor
final class JoinSyncTests: XCTestCase {
    /// A clock the watchdog's sleeps advance, so 120 s pass at once.
    private let clock = EphemeralPresenceClock()

    private func sync(_ namespaceId: String?, store: JustJoinedNamespaces, active: Bool? = nil) -> JoinSync {
        let clock = self.clock
        return JoinSync(
            namespaceId: namespaceId, active: active, store: store,
            sleep: { seconds in
                clock.advance(seconds)
                await Task.yield()
            },
            now: { clock.now })
    }

    func testOnlyAJustJoinedNamespaceIsGated() {
        let store = JustJoinedNamespaces()
        XCTAssertFalse(sync("ns1", store: store).isSyncing)
        store.mark("ns1")
        XCTAssertTrue(sync("ns1", store: store).isSyncing)
        XCTAssertFalse(sync("ns2", store: store).isSyncing)
        XCTAssertFalse(sync(nil, store: store).isSyncing)
    }

    func testSettledLiftsTheGateAndForgetsTheNamespace() {
        let store = JustJoinedNamespaces()
        store.mark("ns1")
        let gate = sync("ns1", store: store)
        XCTAssertTrue(gate.isSyncing)
        gate.update(namespaceId: "ns1", settled: true)
        XCTAssertFalse(gate.isSyncing)
        XCTAssertFalse(store.contains("ns1"))
    }

    func testAMarkOnTheShownNamespaceIsHeard() {
        let store = JustJoinedNamespaces()
        let gate = sync("ns1", store: store)
        XCTAssertFalse(gate.isSyncing)
        store.mark("ns1")
        XCTAssertTrue(gate.isSyncing)
    }

    func testItExpiresAtTheBaseWindowWhenNothingIsInFlight() async {
        let store = JustJoinedNamespaces()
        let start = clock.now
        store.mark("ns1")
        let gate = sync("ns1", store: store)
        let expired = await appLayerEventually { !gate.isSyncing }
        XCTAssertTrue(expired)
        XCTAssertEqual(clock.now.timeIntervalSince(start), JoinSync.watchdog, accuracy: 0.001)
    }

    func testItHoldsWhileActiveButGivesUpAtTheCeiling() async {
        let store = JustJoinedNamespaces()
        let start = clock.now
        store.mark("ns1")
        let gate = sync("ns1", store: store, active: true)
        let expired = await appLayerEventually { !gate.isSyncing }
        XCTAssertTrue(expired)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), JoinSync.maximum)
    }

    func testItCanBeDismissed() {
        let store = JustJoinedNamespaces()
        store.mark("ns1")
        let gate = sync("ns1", store: store)
        gate.dismiss()
        XCTAssertFalse(gate.isSyncing)
        XCTAssertFalse(store.contains("ns1"))
    }

    func testMarkingTwiceDoesNotDuplicate() {
        let store = JustJoinedNamespaces()
        var heard = 0
        _ = store.subscribe { heard += 1 }
        store.mark("ns1")
        store.mark("ns1")
        XCTAssertEqual(heard, 1)
        XCTAssertEqual(store.namespaces, ["ns1"])
    }
}

/// Port of mero-react `join/useJoinInvitation.node.test.tsx`.
@MainActor
final class JoinInvitationTests: XCTestCase {
    func testANodeJoinsTheNamespaceAndTheNamedContext() async {
        let node = AppLayerNode()
        node.install()
        defer { MockURLProtocol.reset() }
        let client = MeroClient(
            session: MockURLProtocol.makeSession(),
            webAuthenticator: AppLayerLoginSheet(nodeURL: "https://node.join.test"),
            storage: MeroAppStorage(defaults: appLayerDefaults()), authStateStore: AuthLoginStateStore())
        await client.connectToNode("https://node.join.test", callbackScheme: "myapp")
        let join = JoinInvitation(client: client)

        let alone = await join.join(JoinInvitationInput(namespaceId: "ns1", invitation: invitationFlowInvitation()))
        XCTAssertEqual(alone, .ok)
        XCTAssertEqual(node.joinPaths, ["/admin-api/namespaces/ns1/join"])

        let withContext = await join.join(
            JoinInvitationInput(namespaceId: "ns1", contextId: "c1", invitation: invitationFlowInvitation()))
        XCTAssertEqual(withContext, .ok)
        XCTAssertEqual(node.joinPaths.last, "/admin-api/contexts/c1/join")
        await client.logout()
    }

    func testAnAccountWithNoCredentialIsToldToSignIn() async {
        let session = MockURLProtocol.makeSession()
        let cloud = CloudSignIn(
            keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore(), urlSession: session,
            delegatedStore: .memory())
        let client = MeroClient(session: session, cloud: cloud, storage: MeroAppStorage(defaults: appLayerDefaults()))
        let bootstrap = DelegatedBootstrap(client: client)
        let result = await bootstrap.bootstrap(namespaceId: "ns1", invitation: invitationFlowInvitation())
        XCTAssertEqual(result.failure?.step, .noCredential)
        let needs = await bootstrap.needsBootstrap()
        XCTAssertFalse(needs, "never enrolled: another door")
    }

    func testFinalityOfAnAccountsJoinFailure() {
        XCTAssertTrue(JoinInvitation.isFinal(BootstrapFailure(step: .admit, reason: "", status: 403)))
        XCTAssertFalse(JoinInvitation.isFinal(BootstrapFailure(step: .admit, reason: "", status: 409)))
        XCTAssertTrue(JoinInvitation.isFinal(BootstrapFailure(step: .notInvited, reason: "")))
        XCTAssertFalse(JoinInvitation.isFinal(BootstrapFailure(step: .noNodes, reason: "")))
    }
}
