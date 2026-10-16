import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A clock a link-state test can move.
final class CloudLinkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}

/// Port of mero-js `link-redirect.test.ts`, `link-callback-state.test.ts`,
/// `account-link-grant.test.ts` and the `callbackIsForeign` cases of
/// `enrol-redirect.test.ts`.
final class CloudLinkFlowTests: XCTestCase {
    private let account = String(repeating: "1f", count: 32)
    private let other = String(repeating: "2e", count: 32)
    private let returnTo = "https://app.example/connected"
    private let grantRootSecret = "5b6b8a1e9f2c47d3a80e6f14c2b9d75380af4e21c6d3b95f7e08a1c4d2f63b97"
    private let grantRootPublicKey = "a021d221f1e7601e8d280c857f8a667383e3923dda13b55f21ca2d928b79c70c"
    private let grantAccount = "ca7645ffd4d0621d00c6c88743aeace5797135ab298c49e77de066206090b778"
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

    /// The `callback-url` a consent URL carries.
    private func callbackURL(of consent: URL) throws -> URL {
        let items = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = try XCTUnwrap(items.first { $0.name == "callback-url" }?.value)
        return try XCTUnwrap(URL(string: value))
    }

    /// What the cloud sends the person back to: the callback plus a fragment.
    private func answer(_ consent: URL, account: String, grant: String = "attacker-grant") throws -> URL {
        let back = try callbackURL(of: consent).absoluteString
        return try XCTUnwrap(URL(string: "\(back)#grant=\(grant)&account=\(account)"))
    }

    /// Begin a link for `linkAccount` and answer it as the cloud would, for `account`.
    private func begunAnswer(_ store: CloudLinkStateStore, for linkAccount: String? = nil) throws -> URL {
        let begun = linkAccount ?? account
        let consent = try CloudLink.cloudLinkUrl(accountId: begun, returnTo: returnTo, stateStore: store)
        return try answer(consent, account: begun)
    }

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func assertRefusedAsForeign(
        _ url: URL, _ store: CloudLinkStateStore, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try CloudLink.readCloudLinkCallback(url, stateStore: store), file: file, line: line) {
            XCTAssertEqual($0 as? AccountError, .stateMismatch, file: file, line: line)
        }
    }

    // MARK: - cloudLinkUrl

    func testCloudLinkUrlNamesTheAccountAndWhereToComeBackTo() throws {
        let store = CloudLinkStateStore()
        let url = try CloudLink.cloudLinkUrl(
            accountId: account, returnTo: "https://app.example/back", stateStore: store)
        XCTAssertEqual(url.host, "cloud.calimero.network")
        XCTAssertEqual(url.path, "/")
        XCTAssertEqual(query(url, "link-account"), account)
        let back = try callbackURL(of: url)
        XCTAssertEqual(back.host, "app.example")
        XCTAssertEqual(back.path, "/back")
        let state = try XCTUnwrap(query(back, "link_state"))
        XCTAssertEqual(state.count, 32)
        XCTAssertTrue(state.allSatisfy(\.isHexDigit))
    }

    func testCloudLinkUrlRefusesAnAccountIdTheCloudWouldReject() {
        XCTAssertThrowsError(
            try CloudLink.cloudLinkUrl(accountId: account.uppercased(), returnTo: returnTo, stateStore: .init())
        ) { XCTAssertTrue("\($0)".contains("64 lowercase hex")) }
    }

    func testGivesEachConsentURLItsOwnState() throws {
        let store = CloudLinkStateStore()
        let a = try callbackURL(of: CloudLink.cloudLinkUrl(accountId: account, returnTo: returnTo, stateStore: store))
        let b = try callbackURL(of: CloudLink.cloudLinkUrl(accountId: account, returnTo: returnTo, stateStore: store))
        XCTAssertNotEqual(query(a, "link_state"), query(b, "link_state"))
    }

    // MARK: - readCloudLinkCallback

    func testReadCloudLinkCallbackIsNilOnAnOrdinaryURL() throws {
        XCTAssertNil(try CloudLink.readCloudLinkCallback(URL(string: returnTo)!, stateStore: .init()))
    }

    func testReadsTheGrantTheCloudHandedBackOnce() throws {
        let store = CloudLinkStateStore()
        let back = try begunAnswer(store)
        XCTAssertEqual(
            try CloudLink.readCloudLinkCallback(back, stateStore: store),
            CloudLinkCallback(grant: "attacker-grant", account: account))
        assertRefusedAsForeign(back, store)
    }

    func testThrowsWhenThePersonDeclinedAndForgetsTheLink() throws {
        let store = CloudLinkStateStore()
        let back = try begunAnswer(store)
        var declined = URLComponents(url: back, resolvingAgainstBaseURL: false)!
        declined.fragment = "error=denied"
        XCTAssertThrowsError(try CloudLink.readCloudLinkCallback(declined.url!, stateStore: store)) {
            guard case AccountError.linkDeclined(let message) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("declined"))
        }
        assertRefusedAsForeign(back, store)
    }

    func testRefusesAGrantWhenThisAppBeganNoLink() {
        let unsolicited = URL(string: "\(returnTo)#grant=attacker-grant&account=\(account)")!
        assertRefusedAsForeign(unsolicited, CloudLinkStateStore())
    }

    func testRefusesAGrantWithTheWrongStateAndKeepsThePendingLink() throws {
        let store = CloudLinkStateStore()
        let back = try begunAnswer(store)
        assertRefusedAsForeign(URL(string: "\(returnTo)?link_state=guessed#grant=x&account=\(account)")!, store)
        for state in ["__proto__", "constructor", "toString", "hasOwnProperty"] {
            assertRefusedAsForeign(URL(string: "\(returnTo)?link_state=\(state)#grant=g&account=\(account)")!, store)
        }
        XCTAssertEqual(try CloudLink.readCloudLinkCallback(back, stateStore: store)?.grant, "attacker-grant")
    }

    func testRefusesAGrantForAnotherAccountAndSpendsTheState() throws {
        let store = CloudLinkStateStore()
        let consent = try CloudLink.cloudLinkUrl(accountId: account, returnTo: returnTo, stateStore: store)
        assertRefusedAsForeign(try answer(consent, account: other), store)
        assertRefusedAsForeign(try answer(consent, account: account), store)
    }

    func testKeepsLinksForTwoAccountsApartAndEarlierURLsValid() throws {
        let store = CloudLinkStateStore()
        let first = try begunAnswer(store)
        _ = try CloudLink.cloudLinkUrl(accountId: account, returnTo: returnTo, stateStore: store)
        let b = try begunAnswer(store, for: other)
        XCTAssertEqual(try CloudLink.readCloudLinkCallback(b, stateStore: store)?.account, other)
        XCTAssertEqual(try CloudLink.readCloudLinkCallback(first, stateStore: store)?.account, account)
    }

    func testRefusesACallbackAfterTheLinkHasExpired() throws {
        let clock = CloudLinkClock()
        let store = CloudLinkStateStore(now: { clock.now() })
        let back = try begunAnswer(store)
        clock.advance(11 * 60)
        assertRefusedAsForeign(back, store)
    }

    func testDoesNotBeginALinkForAnInvalidReturnURL() throws {
        let store = CloudLinkStateStore()
        let back = try begunAnswer(store)
        XCTAssertThrowsError(try CloudLink.cloudLinkUrl(accountId: other, returnTo: "/relative", stateStore: store))
        XCTAssertThrowsError(
            try CloudLink.cloudLinkUrl(accountId: other, returnTo: "https://a.example/#x", stateStore: store))
        XCTAssertEqual(store.pendingCount(), 1)
        XCTAssertEqual(try CloudLink.readCloudLinkCallback(back, stateStore: store)?.account, account)
    }

    func testSurvivesAnUnreadableStoreAndBoundsPendingLinks() throws {
        let store = CloudLinkStateStore(store: .memory(PendingCloudLinks(entries: [:])))
        for _ in 0..<30 { _ = try CloudLink.cloudLinkUrl(accountId: account, returnTo: returnTo, stateStore: store) }
        XCTAssertEqual(store.pendingCount(), CloudLinkStateStore.maxPending)
    }

    func testKeepsLinksAcrossStoreInstancesOverTheSameBacking() throws {
        let backing = AnyValueStore<PendingCloudLinks>.memory()
        let back = try answer(
            try CloudLink.cloudLinkUrl(
                accountId: account, returnTo: returnTo, stateStore: CloudLinkStateStore(store: backing)),
            account: account)
        // A later launch: a new store over the same Keychain item.
        XCTAssertEqual(
            try CloudLink.readCloudLinkCallback(back, stateStore: CloudLinkStateStore(store: backing))?.account,
            account)
    }

    func testStripsTheCallbackFromAKeptURL() {
        let url = URL(string: "https://app.example/connected?keep=1&link_state=abc#grant=g&account=a")!
        XCTAssertEqual(CloudLink.strippingCallback(url).absoluteString, "https://app.example/connected?keep=1")
    }

    // MARK: - completeCloudLink

    func testCompleteCloudLinkRefusesAGrantForAnotherAccountBeforeSendingAnything() async {
        do {
            _ = try await CloudLink.completeCloudLink(
                CloudLinkCallback(grant: "abc.def", account: String(repeating: "aa", count: 32)),
                root: .secret(String(repeating: "07", count: 32)), cloudBaseURL: URL(string: "https://cloud.test")!,
                session: MockURLProtocol.makeSession())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("minted for a different account"), "\(error)")
        }
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testCompleteCloudLinkSpendsTheGrantAnonymously() async throws {
        rig.on("POST", "/api/cloud/accounts/link", json: #"{"account_id":"\#(grantAccount)","already_linked":false}"#)
        let link = try await CloudLink.completeCloudLink(
            CloudLinkCallback(grant: "abc.def", account: grantAccount), root: .secret(grantRootSecret),
            cloudBaseURL: URL(string: "https://cloud.test")!, session: MockURLProtocol.makeSession())
        XCTAssertEqual(link.accountId, grantAccount)
        XCTAssertEqual(rig.seen.first?.json?["grant"], "abc.def")
    }

    // MARK: - The portal handoff

    func testAccountLinkHandoffBuildsTheURLThePortalParses() throws {
        let handoff = try CloudClient.accountLinkHandoff(
            portalURL: "https://cloud.calimero.network/", accountId: grantAccount,
            callbackURL: "https://demo.example/app?keep=this", stateStore: CloudLinkStateStore())
        XCTAssertEqual(handoff.accountId, grantAccount)
        XCTAssertTrue(handoff.url.absoluteString.hasPrefix("https://cloud.calimero.network/?link-account="))
        XCTAssertEqual(query(handoff.url, "link-account"), grantAccount)
        let back = try callbackURL(of: handoff.url)
        XCTAssertEqual(query(back, "keep"), "this")
        XCTAssertEqual(query(back, "link_state")?.count, 32)
    }

    func testAccountLinkHandoffRefusesAnUppercaseAccount() {
        XCTAssertThrowsError(
            try CloudClient.accountLinkHandoff(
                portalURL: "https://cloud.calimero.network", accountId: account.uppercased(), callbackURL: returnTo,
                stateStore: CloudLinkStateStore())
        ) { XCTAssertTrue("\($0)".contains("64 lowercase hex")) }
    }

    func testReadAccountLinkCallbackReadsAGrantOnce() throws {
        let store = CloudLinkStateStore()
        let handoff = try CloudClient.accountLinkHandoff(
            portalURL: "https://cloud.calimero.network", accountId: account, callbackURL: returnTo, stateStore: store)
        let back = try answer(handoff.url, account: account).absoluteString
        XCTAssertEqual(
            CloudClient.readAccountLinkCallback(back, stateStore: store),
            AccountLinkCallback(grant: "attacker-grant", accountId: account))
        XCTAssertEqual(
            CloudClient.readAccountLinkCallback(back, stateStore: store),
            AccountLinkCallback(error: "unexpected_callback"))
    }

    func testReadAccountLinkCallbackRefusesForeignAndMismatchedGrants() throws {
        let store = CloudLinkStateStore()
        XCTAssertEqual(
            CloudClient.readAccountLinkCallback(
                "\(returnTo)#grant=attacker-grant&account=\(account)", stateStore: store),
            AccountLinkCallback(error: "unexpected_callback"))
        let handoff = try CloudClient.accountLinkHandoff(
            portalURL: "https://cloud.calimero.network", accountId: account, callbackURL: returnTo, stateStore: store)
        let mismatched = CloudClient.readAccountLinkCallback(
            try answer(handoff.url, account: other).absoluteString, stateStore: store)
        XCTAssertNil(mismatched.grant)
        XCTAssertEqual(mismatched.error, "unexpected_callback")
    }

    func testReadAccountLinkCallbackReportsARefusalAndIgnoresEverythingElse() {
        let store = CloudLinkStateStore()
        XCTAssertEqual(
            CloudClient.readAccountLinkCallback("https://demo.example/app#error=denied", stateStore: store),
            AccountLinkCallback(error: "denied"))
        XCTAssertEqual(CloudClient.readAccountLinkCallback("https://demo.example/app", stateStore: store), .init())
        XCTAssertEqual(CloudClient.readAccountLinkCallback("not a url", stateStore: store), .init())
        XCTAssertEqual(
            CloudClient.readAccountLinkCallback("https://demo.example/app?grant=sealed.token", stateStore: store),
            .init(), "a grant in the query is never read")
    }

    func testLinkAccountWithGrantSignsTheGrantAndSendsNoAuthorization() async throws {
        let linked = #"{"account_id":"\#(grantAccount)","linked_at":"l","already_linked":false}"#
        rig.on("POST", "/api/cloud/accounts/link") { seen in
            seen.json?["grant"]?.stringValue == "spent.token"
                ? CloudRig.stub(403, #"{"detail":"That grant has already been used."}"#)
                : CloudRig.stub(200, linked)
        }
        let cloud = CloudClient(
            baseURL: URL(string: "https://cloud.test")!, sessionToken: "someone.elses.token",
            session: MockURLProtocol.makeSession())
        let link = try await cloud.linkAccountWithGrant(grant: "grant.one", rootSecret: grantRootSecret)
        _ = try await cloud.linkAccountWithGrant(grant: "grant.two", rootSecret: grantRootSecret)
        XCTAssertEqual(link, CloudAccountLink(accountId: grantAccount, linkedAt: "l", alreadyLinked: false))

        let sent = rig.requests("POST", "/api/cloud/accounts/link")
        XCTAssertEqual(sent.first?.url.absoluteString, "https://cloud.test/api/cloud/accounts/link")
        XCTAssertNil(sent.first?.headers["authorization"])
        let body = try XCTUnwrap(sent.first?.json)
        XCTAssertEqual(body["root_public_key"]?.stringValue, grantRootPublicKey)
        XCTAssertNil(body["account_id"])
        XCTAssertNil(body["email"])
        let expected = try await signAccountLink(AccountLinkInput(rootSecret: grantRootSecret, nonce: "grant.one"))
        XCTAssertEqual(body["signature"]?.stringValue, expected)
        XCTAssertNotEqual(sent.first?.json?["signature"], sent.last?.json?["signature"])

        do {
            _ = try await cloud.linkAccountWithGrant(grant: "spent.token", rootSecret: grantRootSecret)
            XCTFail("a spent grant is refused")
        } catch MeroError.http(let http) {
            XCTAssertEqual(http.bodyText?.contains("already been used"), true)
        }
    }

    // MARK: - callbackIsForeign

    func testCallbackIsForeign() {
        XCTAssertFalse(callbackIsForeign("https://app.example/cb", pageOrigin: "https://app.example"))
        XCTAssertTrue(callbackIsForeign("https://elsewhere.example/cb", pageOrigin: "https://app.example"))
        XCTAssertTrue(callbackIsForeign("https://app.example:8443/cb", pageOrigin: "https://app.example"))
        XCTAssertTrue(callbackIsForeign("http://localhost:3000/cb", pageOrigin: "http://localhost:3001"))
        XCTAssertFalse(callbackIsForeign("https://app.example:443/cb", pageOrigin: "https://APP.example"))
        XCTAssertFalse(callbackIsForeign("https://app.example/cb", pageOrigin: nil))
        XCTAssertFalse(callbackIsForeign("not a url", pageOrigin: "https://app.example"))
        XCTAssertTrue(callbackIsForeign("mero-sample://enrol", pageOrigin: "https://app.example"))
    }
}
