import XCTest

@testable import MeroKit

/// Full end-to-end journeys driven entirely by ``FakeNode`` (no live node).
/// These exercise the whole SDK the way an app would, and assert the auth
/// state machine behaves across a realistic sequence of calls.
final class EndToEndMockTests: XCTestCase {
    private var node: FakeNode!
    private var mero: Mero!
    private var store: MemoryTokenStore!

    override func setUp() {
        super.setUp()
        node = FakeNode()
        node.install()
        store = MemoryTokenStore()
        mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5, tokenStore: store),
            session: MockURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        node = nil
        mero = nil
        store = nil
        super.tearDown()
    }

    /// Login → probe node → authenticate → identity → list contexts → rpc → logout.
    func testHappyPathJourney() async throws {
        // Pre-auth, node metadata is reachable.
        let health = try await mero.auth.getHealth()
        XCTAssertEqual(health.status, "alive")
        let providers = try await mero.auth.getProviders()
        XCTAssertEqual(providers.count, 1)

        // Authenticate.
        let tokens = try await mero.authenticate(Credentials(username: "dev", password: "dev-password"))
        XCTAssertEqual(tokens.accessToken, "access-1")
        let authed = await mero.isAuthenticated
        XCTAssertTrue(authed)

        // The stored access token validates.
        let validation = await mero.auth.validateToken(tokens.accessToken)
        XCTAssertTrue(validation.valid)

        // Identity + a protected admin call.
        let identity = try await mero.auth.getIdentity()
        XCTAssertEqual(identity.authenticationMode, "embedded")
        let contexts = try await mero.admin.getContexts()
        XCTAssertEqual(contexts.contexts.count, 0)

        // A contract call.
        let value: Int = try await mero.rpc.execute(contextId: "ctx", method: "get")
        XCTAssertEqual(value, 42)

        // Logout clears everything.
        await mero.logout()
        let stillAuthed = await mero.isAuthenticated
        XCTAssertFalse(stillAuthed)
        XCTAssertNil(store.getTokens())
        XCTAssertEqual(node.refreshCalls, 0, "no refresh should happen on the happy path")
    }

    /// Access token expires mid-journey → a protected call triggers exactly one
    /// refresh and then succeeds; the rotated bundle is persisted.
    func testRefreshMidJourney() async throws {
        _ = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
        XCTAssertEqual(store.getTokens()?.accessToken, "access-1")

        // Simulate the access token expiring on the node.
        node.expireAccessToken()

        // Next protected call: 401 token_expired → refresh → retry succeeds.
        let value: Int = try await mero.rpc.execute(contextId: "ctx", method: "get")
        XCTAssertEqual(value, 42)

        XCTAssertEqual(node.refreshCalls, 1, "exactly one refresh")
        XCTAssertEqual(store.getTokens()?.accessToken, "access-2", "rotated access token persisted")
        XCTAssertEqual(store.getTokens()?.refreshToken, "refresh-2", "rotated refresh token persisted")
    }

    /// Eight concurrent protected calls after expiry must share a single refresh
    /// (single-use refresh tokens — a double refresh would revoke the family).
    func testConcurrentCallsShareOneRefresh() async throws {
        _ = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
        node.expireAccessToken()

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await self.mero.rpc.execute(contextId: "ctx", method: "get") }
            }
            for try await value in group { XCTAssertEqual(value, 42) }
        }

        XCTAssertEqual(node.refreshCalls, 1, "concurrent 401s must share one refresh")
    }

    /// A revoked family surfaces as `authRevoked` and clears the local bundle.
    func testRevokedFamilyForcesReLogin() async throws {
        _ = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
        node.revokeFamily()

        do {
            let _: Int = try await mero.rpc.execute(contextId: "ctx", method: "get")
            XCTFail("expected authRevoked")
        } catch let error as MeroError {
            guard case .authRevoked(let reason, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(reason, "token_reuse")
        }

        let authed = await mero.isAuthenticated
        XCTAssertFalse(authed)
        XCTAssertNil(store.getTokens())
    }

    /// Re-authenticating after a revoke recovers a working session.
    func testReAuthenticateAfterRevoke() async throws {
        _ = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
        node.revokeFamily()
        _ = try? await mero.rpc.execute(contextId: "ctx", method: "get") as Int

        // Fresh login mints a new family; protected calls work again.
        let tokens = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
        XCTAssertEqual(tokens.accessToken, "access-2")
        let value: Int = try await mero.rpc.execute(contextId: "ctx", method: "get")
        XCTAssertEqual(value, 42)
    }
}
