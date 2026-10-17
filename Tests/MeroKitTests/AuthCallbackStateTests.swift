import XCTest

@testable import MeroKit

/// Tokens in a login callback are only adopted for a login this app began.
/// (Port of mero-js `auth/auth-callback-state.test.ts`.)
///
/// Anyone can hand the app a URL with tokens of their choosing in the
/// fragment; adopting them signs the person in to the sender's node and
/// account.
final class AuthCallbackStateTests: XCTestCase {
    private let node = "https://node.example"
    private let tokens = "access_token=a&refresh_token=r&node_url=https%3A%2F%2Fnode.example"
    private let attacker = "access_token=att&refresh_token=att&node_url=https%3A%2F%2Fevil.example"

    /// What the node's login page sends the person back to: the callback URL
    /// it was given, plus the tokens.
    private func callback(for loginURL: String, fragment: String? = nil) throws -> String {
        let items = try XCTUnwrap(URLComponents(string: loginURL)?.queryItems)
        let back = try XCTUnwrap(items.first { $0.name == "callback-url" }?.value)
        return back + "#" + (fragment ?? tokens)
    }

    private func beginLogin(
        _ store: AuthLoginStateStore, callbackUrl: String = "https://app.example/cb"
    ) -> String {
        SsoLogin.buildAuthLoginUrl(
            nodeUrl: node, options: AuthLoginOptions(callbackUrl: callbackUrl, mode: "admin"), stateStore: store)
    }

    func testRefusesTokensWhenNoLoginWasBegun() {
        let store = AuthLoginStateStore()
        XCTAssertNil(SsoLogin.parseAuthCallback("https://app.example/cb#\(attacker)", stateStore: store))
    }

    func testRefusesAStateThisAppDidNotBegin() {
        let store = AuthLoginStateStore()
        _ = beginLogin(store)
        XCTAssertNil(
            SsoLogin.parseAuthCallback("https://app.example/cb?auth_state=guessed#\(attacker)", stateStore: store))
    }

    func testAdoptsTheLoginItBeganAndKeepsTheCallbackQuery() throws {
        let store = AuthLoginStateStore()
        let back = try callback(for: beginLogin(store, callbackUrl: "https://app.example/cb?tab=files"))
        let query = URLComponents(string: back)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "tab" }?.value, "files")
        let result = SsoLogin.parseAuthCallback(back, stateStore: store)
        XCTAssertEqual(result?.accessToken, "a")
        XCTAssertEqual(result?.refreshToken, "r")
        XCTAssertEqual(result?.nodeUrl, node)
    }

    func testAdoptsACallbackOnce() throws {
        let store = AuthLoginStateStore()
        let back = try callback(for: beginLogin(store))
        XCTAssertNotNil(SsoLogin.parseAuthCallback(back, stateStore: store))
        XCTAssertNil(SsoLogin.parseAuthCallback(back, stateStore: store), "a replayed callback is refused")
    }

    func testRefusesALoginBegunTooLongAgo() throws {
        let clock = AuthStateClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = AuthLoginStateStore(now: { clock.now })
        let back = try callback(for: beginLogin(store))
        clock.advance(11 * 60)
        XCTAssertNil(SsoLogin.parseAuthCallback(back, stateStore: store))
    }

    func testAcceptsWithinTheLifetime() throws {
        let clock = AuthStateClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = AuthLoginStateStore(now: { clock.now })
        let back = try callback(for: beginLogin(store))
        clock.advance(9 * 60)
        XCTAssertNotNil(SsoLogin.parseAuthCallback(back, stateStore: store))
    }

    /// The Swift analog of "does not accept the state of an account link":
    /// a state some other flow (here, a device enrolment) made is not a login.
    func testDoesNotAcceptAStateFromAnotherFlow() {
        let store = AuthLoginStateStore()
        _ = beginLogin(store)
        let enrolmentState = DeviceEnrolment.makeState()
        XCTAssertNil(
            SsoLogin.parseAuthCallback(
                "https://app.example/cb?auth_state=\(enrolmentState)#\(tokens)", stateStore: store))
    }

    func testAStateBegunInAnotherStoreIsNotAccepted() throws {
        let back = try callback(for: beginLogin(AuthLoginStateStore()))
        XCTAssertNil(SsoLogin.parseAuthCallback(back, stateStore: AuthLoginStateStore()))
    }

    /// A pluggable backing store survives the `AuthLoginStateStore` that
    /// wrote it — the shape of a login begun before a relaunch (Keychain).
    func testPendingLoginsLiveInThePluggableStore() throws {
        let backing = AnyValueStore<PendingAuthLogins>.memory()
        let back = try callback(for: beginLogin(AuthLoginStateStore(store: backing)))
        XCTAssertEqual(backing.load()?.expiries.count, 1)
        let relaunched = AuthLoginStateStore(store: backing)
        XCTAssertNotNil(SsoLogin.parseAuthCallback(back, stateStore: relaunched))
        XCTAssertEqual(backing.load()?.expiries.count, 0, "consumed")
    }

    func testKeepsAtMostTwentyPendingLogins() {
        let clock = AuthStateClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = AuthLoginStateStore(now: { clock.now })
        let first = store.begin()
        for _ in 0..<AuthLoginStateStore.maxPending {
            clock.advance(1)
            _ = store.begin()
        }
        XCTAssertFalse(store.take(first), "the oldest was dropped")
    }

    func testAcceptsUnsolicitedTokensOnlyWhenTheCallerOptsIn() {
        let desktop = "https://app.example/#\(tokens)"
        XCTAssertNil(Mero.parseAuthCallback(desktop))
        let accepted = Mero.parseAuthCallback(desktop, options: ParseAuthCallbackOptions(allowUnsolicited: true))
        XCTAssertEqual(accepted?.accessToken, "a")
        XCTAssertEqual(accepted?.nodeUrl, node)
    }

    func testMeroStaticsShareTheDefaultStore() throws {
        let login = Mero.buildAuthLoginUrl(
            nodeUrl: node, options: AuthLoginOptions(callbackUrl: "myapp://auth-callback", mode: "login"))
        let back = try callback(for: login)
        XCTAssertEqual(Mero.parseAuthCallback(back)?.accessToken, "a")
        XCTAssertNil(Mero.parseAuthCallback(back))
    }

    // MARK: - URL shape (byte-identical with mero-js)

    /// mero-js `buildAuthLoginUrl` for the same input, with the state it drew:
    /// `URLSearchParams` form-encodes every value, and the state rides in the
    /// callback URL's query.
    func testLoginURLMatchesMeroJs() throws {
        let store = AuthLoginStateStore()
        let url = SsoLogin.buildAuthLoginUrl(
            nodeUrl: "https://node.example/",
            options: AuthLoginOptions(
                callbackUrl: "myapp://cb", mode: "login", packageName: "com.acme.app",
                permissions: ["admin", "context"], registryUrl: "https://registry.example",
                packageVersion: "1.2.3"),
            stateStore: store)
        let back = try callback(for: url, fragment: "")
        let state = try XCTUnwrap(back.dropLast().components(separatedBy: "auth_state=").last)
        XCTAssertEqual(state.count, 32)
        XCTAssertEqual(
            url,
            "https://node.example/auth/login?callback-url=myapp%3A%2F%2Fcb%3Fauth_state%3D\(state)"
                + "&permissions=admin%2Ccontext&mode=login&package-name=com.acme.app&package-version=1.2.3"
                + "&registry-url=https%3A%2F%2Fregistry.example")
    }

    func testStateIsAddedToTheCallbackQuery() {
        XCTAssertEqual(
            SsoLogin.withState("https://app.example/cb", state: "ab"), "https://app.example/cb?auth_state=ab")
        XCTAssertEqual(
            SsoLogin.withState("https://app.example/cb?tab=files", state: "ab"),
            "https://app.example/cb?tab=files&auth_state=ab")
        XCTAssertEqual(
            SsoLogin.withState("https://app.example/cb?auth_state=old&x=1", state: "ab"),
            "https://app.example/cb?x=1&auth_state=ab", "replaced, not doubled")
        XCTAssertEqual(SsoLogin.withState("myapp://auth-callback", state: "ab"), "myapp://auth-callback?auth_state=ab")
    }

    func testFormEncodingMatchesURLSearchParams() {
        XCTAssertEqual(SsoLogin.formEncode("a b&c=d/é*-._~"), "a+b%26c%3Dd%2F%C3%A9*-._%7E")
    }
}

/// A settable clock for lifetime tests.
final class AuthStateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
