import MeroKit
import XCTest

/// End-to-end tests against a **live** Calimero node.
///
/// Skipped automatically unless `MERO_E2E_NODE_URL` is set, so they never affect
/// the normal `swift test` / unit CI. The `.github/workflows/e2e.yml` job boots a
/// released `merod` and sets these:
///
///   MERO_E2E_NODE_URL          e.g. http://localhost:4001
///   MERO_E2E_USER              default "dev"
///   MERO_E2E_PASS              default "dev-password"
///   MERO_AUTH_BOOTSTRAP_SECRET first-login setup code (core#3221), optional
final class RealNodeE2ETests: XCTestCase {
    private func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    private func makeClient() throws -> Mero {
        let urlString = try XCTUnwrap(env("MERO_E2E_NODE_URL"), "set by the e2e workflow")
        let url = try XCTUnwrap(URL(string: urlString))
        return Mero(config: MeroConfig(baseURL: url, timeout: 30, tokenStore: MemoryTokenStore()))
    }

    private func skipUnlessConfigured() throws {
        try XCTSkipUnless(
            env("MERO_E2E_NODE_URL") != nil,
            "MERO_E2E_NODE_URL not set — skipping live-node e2e"
        )
    }

    func testNodeIsHealthy() async throws {
        try skipUnlessConfigured()
        let mero = try makeClient()
        let health = try await mero.auth.getHealth()
        XCTAssertEqual(health.status, "alive")
    }

    func testFullAuthJourney() async throws {
        try skipUnlessConfigured()
        let mero = try makeClient()

        // Providers advertise the password auth method.
        let providers = try await mero.auth.getProviders()
        XCTAssertGreaterThan(providers.count, 0)

        // Authenticate (bootstrap secret only matters on a fresh node's first login).
        let creds = Credentials(
            username: env("MERO_E2E_USER") ?? "dev",
            password: env("MERO_E2E_PASS") ?? "dev-password",
            bootstrapSecret: env("MERO_AUTH_BOOTSTRAP_SECRET")
        )
        let tokens = try await mero.authenticate(creds)
        XCTAssertFalse(tokens.accessToken.isEmpty)
        XCTAssertFalse(tokens.refreshToken.isEmpty)

        let authed = await mero.isAuthenticated
        XCTAssertTrue(authed)

        // The freshly minted token validates.
        let validation = await mero.auth.validateToken(tokens.accessToken)
        XCTAssertTrue(validation.valid)

        // A protected admin read succeeds with the bearer token.
        let contexts = try await mero.admin.getContexts()
        XCTAssertGreaterThanOrEqual(contexts.contexts.count, 0)

        // Logout clears local state.
        await mero.logout()
        let stillAuthed = await mero.isAuthenticated
        XCTAssertFalse(stillAuthed)
    }
}
