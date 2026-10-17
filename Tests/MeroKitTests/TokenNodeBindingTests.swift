import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Token persistence is bound to the issuing node.
/// (Port of mero-js `mero-js-token-origin.test.ts`.)
///
/// One store can be shared by several `Mero` instances (the Keychain item is
/// per app, not per node). A bundle node A issued must never be sent to node
/// B: that would hand B a credential for A.
final class TokenNodeBindingTests: XCTestCase {
    private let nodeA = "https://node-a.example"
    private let nodeB = "https://node-b.example"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func bundle(_ name: String) -> TokenData {
        TokenData(
            accessToken: "\(name)-access", refreshToken: "\(name)-refresh",
            expiresAt: Date().addingTimeInterval(3600))
    }

    private func mero(_ base: String, _ store: any TokenStore) -> Mero {
        Mero(
            config: MeroConfig(baseURL: URL(string: base)!, timeout: 5, tokenStore: store),
            session: MockURLProtocol.makeSession())
    }

    /// Answer every request with an empty contexts list, recording the
    /// `Authorization` header each one carried.
    private func recordAuthorization() -> AuthorizationLog {
        let log = AuthorizationLog()
        MockURLProtocol.setHandler { req in
            log.append(req.value(forHTTPHeaderField: "Authorization"))
            return .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"data":{"contexts":[]}}"#.utf8))
        }
        return log
    }

    func testDoesNotSendNodeATokensToNodeBThroughASharedStore() async throws {
        let store = MemoryTokenStore()
        await mero(nodeA, store).setTokenData(bundle("a"))

        let log = recordAuthorization()
        let b = mero(nodeB, store)
        _ = try await b.admin.getContexts()

        XCTAssertEqual(log.values.count, 1)
        XCTAssertFalse(log.values.compactMap { $0 }.first?.contains("a-access") ?? false)
        let authed = await b.isAuthenticated
        XCTAssertFalse(authed)
    }

    func testRestoresTheTokensOnTheNodeThatIssuedThem() async throws {
        let store = MemoryTokenStore()
        await mero(nodeA, store).setTokenData(bundle("a"))

        let log = recordAuthorization()
        let again = mero(nodeA, store)
        _ = try await again.admin.getContexts()

        let authed = await again.isAuthenticated
        XCTAssertTrue(authed)
        XCTAssertEqual(log.values, ["Bearer a-access"])
    }

    func testIgnoresAStoredBundleThatCarriesNoNodeOrigin() async throws {
        let store = MemoryTokenStore()
        store.setTokens(bundle("legacy"))

        let log = recordAuthorization()
        let sdk = mero(nodeA, store)
        _ = try await sdk.admin.getContexts()

        XCTAssertFalse(log.values.compactMap { $0 }.first?.contains("legacy-access") ?? false)
        let authed = await sdk.isAuthenticated
        XCTAssertFalse(authed)
    }

    func testIgnoresAForeignBundleWhenTheRefreshReReadsTheStore() async throws {
        let refreshed = AuthorizationLog()
        let expired = Counter()
        MockURLProtocol.setHandler { req in
            if req.url?.path == "/auth/refresh" {
                let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
                refreshed.append(body?["refresh_token"] as? String)
                return .init(
                    status: 200, headers: [:],
                    body: Data(#"{"data":{"access_token":"b-access-2","refresh_token":"b-refresh-2"}}"#.utf8))
            }
            if expired.increment() == 1 {
                return .init(status: 401, headers: ["x-auth-error": "token_expired"], body: Data("{}".utf8))
            }
            return .init(status: 200, headers: [:], body: Data(#"{"data":{"contexts":[]}}"#.utf8))
        }

        let store = MemoryTokenStore()
        let b = mero(nodeB, store)
        await b.setTokenData(bundle("b"))
        // Node A's instance overwrites the shared store with its own bundle.
        await mero(nodeA, store).setTokenData(bundle("a"))

        _ = try await b.admin.getContexts()

        XCTAssertEqual(refreshed.values, ["b-refresh"], "B refreshes with its own token, never A's")
        let current = await b.currentTokenData()
        XCTAssertEqual(current?.refreshToken, "b-refresh-2")
    }

    func testDoesNotSendTokensAcrossPathPrefixesOnTheSameOrigin() async throws {
        let pairs = [
            ("https://host.example/node1", "https://host.example/node2"),
            ("https://host.example/node2", "https://host.example/node1"),
            ("https://host.example", "https://host.example/node1"),
        ]
        for (issuer, other) in pairs {
            let store = MemoryTokenStore()
            await mero(issuer, store).setTokenData(bundle("a"))

            let log = recordAuthorization()
            let sdk = mero(other, store)
            _ = try await sdk.admin.getContexts()

            XCTAssertFalse(log.values.compactMap { $0 }.first?.contains("a-access") ?? false, "\(issuer) → \(other)")
            let authed = await sdk.isAuthenticated
            XCTAssertFalse(authed, "\(issuer) → \(other)")
        }
    }

    func testTreatsATrailingSlashOnTheBaseURLAsTheSameNode() async throws {
        let store = MemoryTokenStore()
        await mero("https://host.example/node1/", store).setTokenData(bundle("a"))

        let log = recordAuthorization()
        // Held in a local: the transport reads the token through a weak
        // reference, so a temporary `Mero` is gone before the request is sent.
        let again = mero("https://host.example/node1", store)
        _ = try await again.admin.getContexts()

        XCTAssertEqual(log.values, ["Bearer a-access"])
    }

    func testThePersistedCopyNamesTheNodeAndTheLiveOneDoesNot() async {
        let store = MemoryTokenStore()
        let sdk = mero("https://host.example/node1/", store)
        await sdk.setTokenData(bundle("a"))
        XCTAssertEqual(store.getTokens()?.nodeOrigin, "https://host.example/node1")
        let live = await sdk.currentTokenData()
        XCTAssertNil(live?.nodeOrigin)
    }

    // MARK: - The key

    func testNodeKeyIsOriginPlusPathPrefix() {
        func key(_ s: String) -> String { TokenData.nodeKey(for: URL(string: s)!) }
        XCTAssertEqual(key("https://host.example"), "https://host.example")
        XCTAssertEqual(key("https://host.example/"), "https://host.example")
        XCTAssertEqual(key("https://Host.Example:443/node1//"), "https://host.example/node1")
        XCTAssertEqual(key("http://localhost:2428"), "http://localhost:2428")
        XCTAssertEqual(key("http://localhost:80/x"), "http://localhost/x")
        XCTAssertEqual(key("https://host.example/node1?q=1#f"), "https://host.example/node1")
        XCTAssertEqual(key("http://[::1]:2428/"), "http://[::1]:2428")
        XCTAssertEqual(key("myapp://whatever"), "myapp://whatever", "no web origin: the URL itself")
    }

    // MARK: - Wire format

    func testNodeOriginPersistsSnakeCaseAndOldBundlesStillDecode() throws {
        let tagged = TokenData(
            accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            nodeOrigin: "https://node.example")
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: MeroJSON.encode(tagged)) as? [String: Any])
        XCTAssertEqual(json["node_origin"] as? String, "https://node.example")
        XCTAssertEqual(try MeroJSON.decode(TokenData.self, from: MeroJSON.encode(tagged)), tagged)

        let untagged = try MeroJSON.encode(TokenData(accessToken: "a", refreshToken: "r", expiresAt: Date()))
        let untaggedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: untagged) as? [String: Any])
        XCTAssertNil(untaggedJSON["node_origin"], "absent, not null")

        let legacy = Data(#"{"access_token":"a","refresh_token":"r","expires_at":1700000000000}"#.utf8)
        let decoded = try MeroJSON.decode(TokenData.self, from: legacy)
        XCTAssertEqual(decoded.accessToken, "a")
        XCTAssertNil(decoded.nodeOrigin)
    }
}

/// A thread-safe log of optional strings (headers, body fields).
final class AuthorizationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String?] = []

    var values: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }
}
