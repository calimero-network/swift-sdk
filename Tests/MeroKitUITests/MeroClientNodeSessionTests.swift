import Foundation
import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A password login is a session like an SSO one: remembered, restorable after
/// a relaunch, followed over SSE. And a node that cannot be reached at launch
/// is not a node that refused the token.
@MainActor
final class MeroClientNodeSessionTests: XCTestCase {
    private let nodeURL = "https://node.session.test"
    private var node: PasswordNode!

    override func setUp() {
        super.setUp()
        node = PasswordNode()
        node.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        node = nil
        super.tearDown()
    }

    private func makeClient(
        storage: MeroAppStorage, store: MemoryTokenStore, session: URLSession = MockURLProtocol.makeSession(),
        config: MeroProviderConfig = MeroProviderConfig()
    ) -> MeroClient {
        MeroClient(
            session: session, tokenStore: { store }, webAuthenticator: AppLayerLoginSheet(nodeURL: nodeURL),
            config: config, storage: storage, authStateStore: AuthLoginStateStore())
    }

    // MARK: - login(nodeURL:username:password:)

    func testLoginRemembersTheNodeSoRestoreCanBringItBack() async {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        let store = MemoryTokenStore()
        let first = makeClient(storage: storage, store: store)
        await first.login(nodeURL: nodeURL + "/", username: "dev", password: "pw")

        XCTAssertTrue(first.isAuthenticated)
        XCTAssertEqual(first.nodeURL, nodeURL, "the trailing slash is dropped, as connectToNode drops it")
        XCTAssertEqual(storage.nodeURL, nodeURL)
        XCTAssertEqual(storage.tokenNodeURL, nodeURL)
        let online = await appLayerEventually { first.isOnline && self.node.sseConnects > 0 }
        XCTAssertTrue(online, "the login follows the node's event stream")

        // A relaunch: a new client over the same storage and token store.
        let second = makeClient(storage: storage, store: store)
        let restored = await second.restore()
        XCTAssertTrue(restored)
        XCTAssertTrue(second.isAuthenticated)
        XCTAssertEqual(second.nodeURL, nodeURL)
        await first.logout()
        await second.logout()
    }

    func testLoginLooksUpTheApplicationByPackage() async {
        let client = makeClient(storage: MeroAppStorage(defaults: appLayerDefaults()), store: MemoryTokenStore())
        await client.login(nodeURL: nodeURL, username: "dev", password: "pw", packageName: "com.example.notes")
        XCTAssertEqual(client.applicationId, "notes-2", "the latest installed version of the package")
        XCTAssertEqual(client.storage.applicationId, "notes-2")
        await client.logout()
    }

    func testLoginTakesThePackageFromTheConfig() async {
        let client = makeClient(
            storage: MeroAppStorage(defaults: appLayerDefaults()), store: MemoryTokenStore(),
            config: MeroProviderConfig(packageName: "com.example.chat"))
        await client.login(nodeURL: nodeURL, username: "dev", password: "pw")
        XCTAssertEqual(client.applicationId, "chat-1")
        await client.logout()
    }

    func testLoginWithoutAPackageLeavesTheApplicationAlone() async {
        let client = makeClient(storage: MeroAppStorage(defaults: appLayerDefaults()), store: MemoryTokenStore())
        await client.login(nodeURL: nodeURL, username: "dev", password: "pw")
        XCTAssertNil(client.applicationId)
        XCTAssertEqual(node.applicationReads, 0, "nothing to look up")
        await client.logout()
    }

    func testAFailedLoginRemembersNothing() async {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        let client = makeClient(storage: storage, store: MemoryTokenStore())
        await client.login(nodeURL: nodeURL, username: "dev", password: "wrong")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNotNil(client.errorMessage)
        XCTAssertNil(storage.nodeURL)
        XCTAssertNil(storage.tokenNodeURL)
    }

    // MARK: - resumeNodeSession()

    private func signedInStorage() async -> (MeroAppStorage, MemoryTokenStore) {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        let store = MemoryTokenStore()
        let first = makeClient(storage: storage, store: store)
        await first.login(nodeURL: nodeURL, username: "dev", password: "pw")
        XCTAssertTrue(first.isAuthenticated)
        // End the first launch without logging out (that would forget the session).
        await first.node?.close()
        return (storage, store)
    }

    func testResumeRestoresAnAcceptedToken() async {
        let (storage, store) = await signedInStorage()
        let client = makeClient(storage: storage, store: store)
        let result = await client.resumeNodeSession()
        XCTAssertEqual(result, .restored)
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertFalse(client.isOfflineSession)
        await client.logout()
    }

    func testResumeKeepsTheSessionWhenTheNetworkIsDown() async {
        let (storage, store) = await signedInStorage()
        let client = makeClient(storage: storage, store: store, session: OfflineURLProtocol.makeSession())

        let result = await client.resumeNodeSession()
        XCTAssertEqual(result, .offline)
        XCTAssertTrue(client.isAuthenticated, "the held tokens are used")
        XCTAssertTrue(client.isOfflineSession)
        XCTAssertFalse(client.isOnline)
        XCTAssertNotNil(client.transport)
        XCTAssertTrue(client.admin is NodeAdmin)
        let held = await client.node?.currentTokenData()
        XCTAssertNotNil(held, "nothing was cleared")

        // `restoreNodeSession` keeps its answer: no validated session.
        let strict = makeClient(storage: storage, store: store, session: OfflineURLProtocol.makeSession())
        let restored = await strict.restoreNodeSession()
        XCTAssertFalse(restored)
    }

    func testResumeKeepsTheSessionWhenTheNodeAnswers5xx() async {
        let (storage, store) = await signedInStorage()
        node.validateStatus = 503
        let client = makeClient(storage: storage, store: store)
        let result = await client.resumeNodeSession()
        XCTAssertEqual(result, .offline)
        XCTAssertTrue(client.isAuthenticated)
        node.validateStatus = nil
    }

    func testTheOfflineFlagClearsWhenTheNodeComesBack() async {
        let (storage, store) = await signedInStorage()
        node.validateStatus = 503
        let client = makeClient(storage: storage, store: store)
        _ = await client.resumeNodeSession()
        XCTAssertTrue(client.isOfflineSession)
        node.validateStatus = nil
        // The stream retries on its own backoff (3 s, with jitter).
        let back = await appLayerEventually(timeout: 8) { !client.isOfflineSession && client.isOnline }
        XCTAssertTrue(back, "the event stream connected with the held token")
        XCTAssertTrue(client.isAuthenticated)
        await client.logout()
    }

    func testResumeReportsARejectedToken() async {
        let (storage, store) = await signedInStorage()
        node.rejectAll = true
        let client = makeClient(storage: storage, store: store)
        let result = await client.resumeNodeSession()
        XCTAssertEqual(result, .rejected)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertFalse(client.isOfflineSession)
    }

    func testResumeWithNothingStored() async {
        let client = makeClient(storage: MeroAppStorage(defaults: appLayerDefaults()), store: MemoryTokenStore())
        let result = await client.resumeNodeSession()
        XCTAssertEqual(result, .noSession)
    }

    func testResumeWithAStoredNodeButNoToken() async {
        let storage = MeroAppStorage(defaults: appLayerDefaults())
        storage.nodeURL = nodeURL
        let client = makeClient(storage: storage, store: MemoryTokenStore())
        let result = await client.resumeNodeSession()
        XCTAssertEqual(result, .noSession)
        XCTAssertFalse(client.isAuthenticated)
    }
}

/// A development node: `POST /auth/token` for `dev`/`pw`, `/auth/validate`,
/// `/sse`, and two installed packages.
final class PasswordNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _validateStatus: Int?
    private var _rejectAll = false
    private var _sseConnects = 0
    private var _applicationReads = 0

    /// Answer `/auth/validate` and `/sse` with this status instead (a `5xx`).
    var validateStatus: Int? {
        get { locked { _validateStatus } }
        set { locked { _validateStatus = newValue } }
    }

    /// Refuse every bearer with `401`.
    var rejectAll: Bool {
        get { locked { _rejectAll } }
        set { locked { _rejectAll = newValue } }
    }

    var sseConnects: Int { locked { _sseConnects } }
    var applicationReads: Int { locked { _applicationReads } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func install() {
        MockURLProtocol.setHandler { [self] req in handle(req) }
    }

    private func json(_ object: [String: Any], status: Int = 200) -> MockURLProtocol.Stub {
        .init(
            status: status, headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func authorized(_ req: URLRequest) -> Bool {
        !rejectAll && req.value(forHTTPHeaderField: "Authorization") == "Bearer good"
    }

    private func handle(_ req: URLRequest) -> MockURLProtocol.Stub {
        let path = req.url?.path ?? ""
        switch path {
        case "/auth/token":
            let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
            let provider = body?["provider_data"] as? [String: Any]
            guard provider?["password"] as? String == "pw" else {
                return json(["error": "invalid credentials"], status: 401)
            }
            return json(["data": ["access_token": "good", "refresh_token": "r1"]])
        case "/auth/validate":
            if let status = validateStatus { return .init(status: status, headers: [:], body: Data()) }
            return .init(status: authorized(req) ? 200 : 401, headers: [:], body: Data())
        case "/auth/logout":
            return json(["data": ["success": true] as [String: Any]])
        case "/sse":
            if let status = validateStatus { return .init(status: status, headers: [:], body: Data()) }
            guard authorized(req) else { return .init(status: 401, headers: [:], body: Data()) }
            locked { _sseConnects += 1 }
            let frame = "data: {\"type\":\"connect\",\"session_id\":\"s1\"}\n\n"
            return .init(
                status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(frame.utf8), holdOpen: true)
        case "/sse/subscription":
            return json(["data": [String: Any]()])
        case "/admin-api/applications":
            guard authorized(req) else { return .init(status: 401, headers: [:], body: Data()) }
            locked { _applicationReads += 1 }
            return json([
                "data": [
                    "apps": [
                        Self.app("notes-1", package: "com.example.notes", version: "1.9.0"),
                        Self.app("notes-2", package: "com.example.notes", version: "1.10.0"),
                        Self.app("chat-1", package: "com.example.chat", version: "0.1.0"),
                    ]
                ]
            ])
        default:
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    static func app(_ id: String, package: String, version: String) -> [String: Any] {
        [
            "id": id, "blob": ["bytecode": "b-\(id)", "compiled": "c-\(id)"], "size": 1, "source": "local",
            "metadata": [Int](), "signer_id": "s", "package": package, "version": version,
        ]
    }
}

/// Every request fails as if the device had no network.
final class OfflineURLProtocol: URLProtocol {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
