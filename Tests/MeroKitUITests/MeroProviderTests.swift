import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// The MeroProvider / useMero port: node SSO login with trust and token
/// adoption, health over SSE, account sessions, capabilities and logout.
/// (mero-react `MeroContext.test.tsx`, as far as it is logic.)
@MainActor
final class MeroProviderTests: XCTestCase {
    private let nodeURL = "https://node.provider.test"
    private var node: AppLayerNode!

    override func setUp() {
        super.setUp()
        node = AppLayerNode()
        node.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        node = nil
        super.tearDown()
    }

    private func makeClient(
        sheet: (any WebAuthenticating)? = nil, config: MeroProviderConfig = MeroProviderConfig(),
        storage: MeroAppStorage = MeroAppStorage(defaults: appLayerDefaults())
    ) -> MeroClient {
        let session = MockURLProtocol.makeSession()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true), sealRelays: false),
            keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore(), urlSession: session,
            delegatedStore: .memory())
        let store = MemoryTokenStore()
        return MeroClient(
            session: session, tokenStore: { store }, cloud: cloud,
            webAuthenticator: sheet ?? AppLayerLoginSheet(nodeURL: nodeURL), config: config, storage: storage,
            authStateStore: AuthLoginStateStore())
    }

    func testPermissionsForEachMode() {
        XCTAssertEqual(
            permissions(for: .multiContext),
            [
                "context:create", "context:delete", "context:list", "context:execute", "context:subscribe",
                "application:list", "namespace", "group", "blob", "context:alias",
            ])
        XCTAssertEqual(permissions(for: .admin), ["admin"])
        XCTAssertTrue(AppMode.singleContext.permissions.contains("context:subscribe"))
        XCTAssertFalse(AppMode.singleContext.permissions.contains("context:create"))
    }

    func testConnectToNodeAdoptsATrustedCallbackAndGoesOnline() async throws {
        let sheet = AppLayerLoginSheet(nodeURL: nodeURL)
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        let client = makeClient(
            sheet: sheet, config: MeroProviderConfig(packageName: "com.example.app"), storage: storage)
        await client.connectToNode(nodeURL + "/", callbackScheme: "myapp")

        XCTAssertNil(client.errorMessage)
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertFalse(client.isDelegated)
        XCTAssertEqual(client.can, .node)
        XCTAssertEqual(client.applicationId, "app1")
        XCTAssertEqual(client.contextId, "ctx1")
        XCTAssertEqual(client.contextIdentity, "me1")
        XCTAssertEqual(storage.nodeURL, nodeURL)
        XCTAssertEqual(storage.tokenNodeURL, nodeURL)
        XCTAssertTrue(client.admin is NodeAdmin)
        XCTAssertNotNil(client.transport)

        let login = try XCTUnwrap(sheet.pages.first)
        XCTAssertEqual(login.path, "/auth/login")
        let query = URLComponents(url: login, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "mode" }?.value, "multi-context")
        XCTAssertEqual(query.first { $0.name == "package-name" }?.value, "com.example.app")
        XCTAssertTrue(query.first { $0.name == "permissions" }?.value?.contains("context:subscribe") == true)
        XCTAssertTrue(query.first { $0.name == "callback-url" }?.value?.hasPrefix("myapp://auth") == true)

        let online = await appLayerEventually { client.isOnline }
        XCTAssertTrue(online)
        await client.logout()
    }

    func testACallbackNamingAnotherNodeIsRejected() async {
        let client = makeClient(sheet: AppLayerLoginSheet(nodeURL: "https://evil.test"))
        await client.connectToNode(nodeURL, callbackScheme: "myapp")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNotNil(client.errorMessage)
        XCTAssertNil(client.storage.tokenNodeURL, "no tokens adopted from an untrusted node")
    }

    func testAnUnsolicitedCallbackIsIgnored() async {
        let client = makeClient()
        let url = URL(string: "myapp://auth#access_token=good&node_url=\(nodeURL)")!
        let handled = await client.handleAuthCallback(url)
        XCTAssertFalse(handled, "a callback for a login this app never began")
        XCTAssertFalse(client.isAuthenticated)
    }

    func testAStreamRefusedForMissingSubscribeGrantLogsOut() async {
        node.sse = .permissionDenied
        let client = makeClient()
        await client.connectToNode(nodeURL, callbackScheme: "myapp")
        XCTAssertTrue(client.isAuthenticated)
        let loggedOut = await appLayerEventually { !client.isAuthenticated }
        XCTAssertTrue(loggedOut, "403 permission_denied on /sse is a token minted without context:subscribe")
        XCTAssertNil(client.storage.nodeURL)
        XCTAssertNil(client.applicationId)
    }

    func testRestoreRevalidatesTheStoredNode() async {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        let first = makeClient(storage: storage)
        await first.connectToNode(nodeURL, callbackScheme: "myapp")
        XCTAssertTrue(first.isAuthenticated)
        let stored = await first.node?.currentTokenData()

        // A new launch with the same token store contents.
        let session = MockURLProtocol.makeSession()
        let store = MemoryTokenStore()
        if var stored {
            stored.nodeOrigin = TokenData.nodeKey(for: URL(string: nodeURL)!)
            store.setTokens(stored)
        }
        let second = MeroClient(
            session: session, tokenStore: { store }, webAuthenticator: AppLayerLoginSheet(nodeURL: nodeURL),
            storage: storage, authStateStore: AuthLoginStateStore())
        let restored = await second.restoreNodeSession()
        XCTAssertTrue(restored)
        XCTAssertEqual(second.applicationId, "app1", "ids come back from storage")
        await first.logout()
        await second.logout()
    }

    func testAnAccountSessionIsDelegatedWithAccountCapabilities() async throws {
        let client = makeClient(config: MeroProviderConfig(packageName: nil))
        client.connectWithAccount(try appLayerSession(relay: nil))
        let connected = await appLayerEventually { client.isAuthenticated }
        XCTAssertTrue(connected)
        XCTAssertTrue(client.isDelegated)
        XCTAssertNil(client.transport, "no relay: no client, and writes say so")
        XCTAssertTrue(client.admin is AccountAdmin, "the empty account admin, never nil")
        let expected = MeroCapabilities(createNamespace: false, createContext: true, invite: true, upgrade: false)
        XCTAssertEqual(client.can, expected)

        let withPackage = makeClient(config: MeroProviderConfig(packageName: "com.example.app"))
        withPackage.connectWithAccount(try appLayerSession(relay: nil))
        _ = await appLayerEventually { withPackage.isAuthenticated }
        XCTAssertTrue(withPackage.can.createNamespace)

        let executor = ContextExecutor(client: client, contextId: "c", executorId: "e")
        let value: Int? = await executor.execute("get")
        XCTAssertNil(value)
        XCTAssertEqual(executor.error as? NotConnectedError, NotConnectedError.noRelay)
    }

    func testLogoutClearsEverything() async {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        let client = makeClient(storage: storage)
        await client.connectToNode(nodeURL, callbackScheme: "myapp")
        XCTAssertTrue(client.isAuthenticated)
        await client.logout()
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(client.admin)
        XCTAssertNil(client.transport)
        XCTAssertNil(client.applicationId)
        XCTAssertNil(client.contextId)
        XCTAssertNil(storage.nodeURL)
        XCTAssertNil(storage.tokenNodeURL)
        XCTAssertNil(storage.contextIdentity)
    }

    func testAppStorageRoundTripsAndClears() {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        storage.nodeURL = "https://n"
        storage.applicationId = "a"
        storage.contextId = ""
        XCTAssertEqual(storage.nodeURL, "https://n")
        XCTAssertEqual(storage.string(for: .applicationId), "a")
        XCTAssertNil(storage.contextId, "an empty value is no value")
        storage.clearAll()
        XCTAssertNil(storage.nodeURL)
        XCTAssertNil(storage.applicationId)
    }
}
