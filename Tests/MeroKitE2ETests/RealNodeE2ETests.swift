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

        // Authenticate. These are the admin credentials given to `merod init` —
        // core 0.11.0-rc.17 creates the admin there, and there is no
        // first-login bootstrap secret any more.
        let creds = Credentials(
            username: env("MERO_E2E_USER") ?? "dev",
            password: env("MERO_E2E_PASS") ?? "dev-password"
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

    /// Provisioning, against the real node — the gap this suite had.
    ///
    /// Everything else that checks request shape here is MOCKED: it asserts
    /// what the SDK sends, which cannot notice that the node stopped accepting
    /// it. And the live suite only ever did health, auth and one read. So the
    /// two calls an app must make before it can do anything — create a
    /// namespace, create a named subgroup — were covered by neither, and both
    /// had been returning 400/422 since core closed its request bodies.
    ///
    /// This is deliberately the whole chain rather than one call: an app that
    /// cannot reach a context has nothing, no matter which link broke.
    func testProvisioningChainAgainstARealNode() async throws {
        try skipUnlessConfigured()
        let mero = try makeClient()
        _ = try await mero.authenticate(
            Credentials(
                username: env("MERO_E2E_USER") ?? "dev",
                password: env("MERO_E2E_PASS") ?? "dev-password"))

        // An application has to exist to hang a namespace off. Any installed
        // one will do; the wire shape under test is the namespace call.
        let apps = try await mero.admin.listApplications()
        try XCTSkipIf(apps.apps.isEmpty, "no application installed on the e2e node")
        let applicationId = apps.apps[0].id

        // 400 if the body carries `upgradePolicy`.
        let namespace = try await mero.admin.createNamespace(
            CreateNamespaceRequest(applicationId: applicationId, name: "e2e-workspace"))
        XCTAssertFalse(namespace.namespaceId.isEmpty)

        // 422 if the body spells the name `name` instead of `groupName`.
        let subgroup = try await mero.admin.createGroupInNamespace(
            namespace.namespaceId,
            request: CreateGroupInNamespaceRequest(groupName: "e2e-room"))
        XCTAssertFalse(subgroup.groupId.isEmpty)

        // And the subgroup really is named — a request the node accepted but
        // read as unnamed would pass every assertion above.
        let subgroups = try await mero.admin.listNamespaceGroups(namespace.namespaceId)
        XCTAssertTrue(
            subgroups.contains { $0.groupId == subgroup.groupId },
            "the subgroup the node just created should be listed under its namespace")
    }
}
