import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Read a request body whether URLSession delivered it inline or as a stream.
private func bodyString(_ request: URLRequest) -> String {
    if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var data = Data()
    let bufSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
}

private func json(_ dict: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: dict)
}

private func mero(store: MemoryTokenStore = MemoryTokenStore()) -> Mero {
    let config = MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5, tokenStore: store)
    return Mero(config: config, session: MockURLProtocol.makeSession())
}

final class AuthenticateTests: XCTestCase {
    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    func testAuthenticateBuildsBodyAndStoresTokens() async throws {
        let captured = CapturedBody()
        MockURLProtocol.setHandler { req in
            if req.url?.path == "/auth/token" {
                captured.value = bodyString(req)
                return .init(
                    status: 200, headers: ["Content-Type": "application/json"],
                    body: json(["data": ["access_token": "ACCESS", "refresh_token": "REFRESH"]]))
            }
            return .init(status: 404, headers: [:], body: Data())
        }

        let store = MemoryTokenStore()
        let sdk = mero(store: store)
        let tokens = try await sdk.authenticate(
            Credentials(username: "alice", password: "pw"))

        XCTAssertEqual(tokens.accessToken, "ACCESS")
        XCTAssertEqual(tokens.refreshToken, "REFRESH")
        XCTAssertEqual(store.getTokens()?.accessToken, "ACCESS")

        let body = try XCTUnwrap(captured.value)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["auth_method"] as? String, "user_password")
        XCTAssertEqual(obj["public_key"] as? String, "alice")
        XCTAssertEqual(obj["client_name"] as? String, "mero-swift-sdk")
        let provider = try XCTUnwrap(obj["provider_data"] as? [String: Any])
        XCTAssertEqual(provider["username"] as? String, "alice")
        XCTAssertEqual(provider["password"] as? String, "pw")
        // Exactly two keys. core 0.11.0-rc.17 deleted the first-login setup
        // code, and rc.29 keeps parsing `bootstrap_secret` only to discard it —
        // so sending one is dead weight that also implies a flow that no longer
        // exists.
        XCTAssertEqual(Set(provider.keys), ["username", "password"])
    }

    /// A login failure must keep saying WHICH failure it was.
    ///
    /// `authenticate` used to catch everything and rethrow
    /// `authenticationFailed`, so an unreachable node told the caller to check
    /// its password. That mislabel is what let a sample app spend five weeks
    /// pointed at a LAN address no CI runner has, reported as bad credentials.
    func testATransportFailureIsNotReportedAsBadCredentials() async {
        MockURLProtocol.setHandler { _ in
            .init(status: 503, headers: [:], body: Data())
        }
        let sdk = mero()
        do {
            _ = try await sdk.authenticate(Credentials(username: "bob", password: "pw"))
            XCTFail("expected a throw")
        } catch let error as MeroError {
            // A 5xx is the node failing, not a credential being wrong. It stays
            // an `.http` so the caller can see the status and decide to retry.
            guard case .http(let http) = error, http.status == 503 else {
                return XCTFail("a 503 must not become authenticationFailed; got \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// The actual iOS symptom: nothing listening at the URL. It has to read as
    /// "cannot reach the node", not as a credential problem, because that is
    /// what a person acts on differently.
    func testAnUnreachableNodeIsNotReportedAsBadCredentials() async {
        // A real connection to a port nothing listens on, so this exercises the
        // transport rather than a stub's idea of one. Port 1 refuses instantly.
        let sdk = Mero(
            config: MeroConfig(
                baseURL: URL(string: "http://127.0.0.1:1")!, timeout: 2,
                tokenStore: MemoryTokenStore()))
        do {
            _ = try await sdk.authenticate(Credentials(username: "bob", password: "pw"))
            XCTFail("expected a throw")
        } catch let error as MeroError {
            guard case .network = error else {
                return XCTFail(
                    "an unreachable host must not become authenticationFailed; got \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testARejectedPasswordStillReportsAuthenticationFailed() async {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 401, headers: ["Content-Type": "application/json"],
                body: json(["error": "invalid credentials"]))
        }
        let sdk = mero()
        do {
            _ = try await sdk.authenticate(Credentials(username: "bob", password: "wrong"))
            XCTFail("expected a throw")
        } catch let error as MeroError {
            guard case .authenticationFailed = error else {
                return XCTFail("a 401 from the node IS an auth failure; got \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testNoCredentialsThrows() async {
        let sdk = mero()
        do {
            _ = try await sdk.authenticate()
            XCTFail("expected throw")
        } catch let error as MeroError {
            if case .noCredentials = error {} else { XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    func testLogoutClearsTokens() async throws {
        MockURLProtocol.setHandler { _ in
            .init(status: 200, headers: [:], body: json(["data": ["access_token": "A", "refresh_token": "R"]]))
        }
        let store = MemoryTokenStore()
        let sdk = mero(store: store)
        _ = try await sdk.authenticate(Credentials(username: "a", password: "b"))
        let before = await sdk.isAuthenticated
        XCTAssertTrue(before)

        await sdk.logout()
        let after = await sdk.isAuthenticated
        XCTAssertFalse(after)
        XCTAssertNil(store.getTokens())
    }
}

final class RefreshStateMachineTests: XCTestCase {
    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    private func seededStore() -> MemoryTokenStore {
        let store = MemoryTokenStore()
        store.setTokens(
            TokenData(accessToken: "OLD", refreshToken: "OLD_REFRESH", expiresAt: Date().addingTimeInterval(3600)))
        return store
    }

    func testRefreshOn401RetriesOnceAndSucceeds() async throws {
        let rpcCalls = Counter()
        let refreshCalls = Counter()

        MockURLProtocol.setHandler { req in
            switch req.url?.path {
            case "/jsonrpc":
                let n = rpcCalls.increment()
                if n == 1 {
                    // First call: access token expired.
                    return .init(status: 401, headers: ["x-auth-error": "token_expired"], body: Data())
                }
                return .init(
                    status: 200, headers: [:],
                    body: json(["jsonrpc": "2.0", "id": 1, "result": ["output": 99]]))
            case "/auth/refresh":
                _ = refreshCalls.increment()
                return .init(
                    status: 200, headers: [:],
                    body: json(["data": ["access_token": "NEW", "refresh_token": "NEW_REFRESH"]]))
            default:
                return .init(status: 404, headers: [:], body: Data())
            }
        }

        let store = seededStore()
        let sdk = mero(store: store)
        let result: Int = try await sdk.rpc.execute(contextId: "ctx", method: "get")

        XCTAssertEqual(result, 99)
        XCTAssertEqual(refreshCalls.count, 1, "refresh must run exactly once")
        XCTAssertEqual(rpcCalls.count, 2, "one 401 + one retry")
        // Rotated bundle persisted.
        XCTAssertEqual(store.getTokens()?.accessToken, "NEW")
        XCTAssertEqual(store.getTokens()?.refreshToken, "NEW_REFRESH")
    }

    func testConcurrent401sTriggerSingleRefresh() async throws {
        let refreshCalls = Counter()
        let rpcCallsByToken = TokenTracker()

        MockURLProtocol.setHandler { req in
            switch req.url?.path {
            case "/jsonrpc":
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                // Requests carrying the OLD token get a 401; NEW token succeeds.
                if auth.contains("OLD") {
                    rpcCallsByToken.recordOld()
                    return .init(status: 401, headers: ["x-auth-error": "token_expired"], body: Data())
                }
                return .init(
                    status: 200, headers: [:],
                    body: json(["jsonrpc": "2.0", "id": 1, "result": ["output": true]]))
            case "/auth/refresh":
                _ = refreshCalls.increment()
                return .init(
                    status: 200, headers: [:],
                    body: json(["data": ["access_token": "NEW", "refresh_token": "NEW_REFRESH"]]))
            default:
                return .init(status: 404, headers: [:], body: Data())
            }
        }

        let store = seededStore()
        let sdk = mero(store: store)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { try await sdk.rpc.execute(contextId: "ctx", method: "get") }
            }
            for try await ok in group { XCTAssertTrue(ok) }
        }

        // A single-use refresh token must be consumed exactly once despite 8 concurrent 401s.
        XCTAssertEqual(refreshCalls.count, 1, "concurrent 401s must share one refresh")
    }

    func testTerminalAuthRevokedClearsTokensAndThrows() async {
        MockURLProtocol.setHandler { req in
            if req.url?.path == "/jsonrpc" {
                return .init(status: 401, headers: ["x-auth-error": "token_reuse"], body: Data())
            }
            return .init(status: 404, headers: [:], body: Data())
        }

        let store = seededStore()
        let sdk = mero(store: store)

        do {
            let _: Bool = try await sdk.rpc.execute(contextId: "ctx", method: "get")
            XCTFail("expected authRevoked")
        } catch let error as MeroError {
            guard case .authRevoked(let reason, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(reason, "token_reuse")
        } catch {
            XCTFail("wrong error type: \(error)")
        }

        // Family gone → tokens cleared, forcing re-login.
        let authed = await sdk.isAuthenticated
        XCTAssertFalse(authed)
        XCTAssertNil(store.getTokens())
    }
}

final class RpcClientTests: XCTestCase {
    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    func testExecuteUnwrapsOutput() async throws {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: [:],
                body: json(["jsonrpc": "2.0", "id": 1, "result": ["output": ["converted": 3, "remaining": 1]]]))
        }
        let sdk = mero()
        let summary = try await sdk.rpc.migrateMyEntries("ctx")
        XCTAssertEqual(summary.converted, 3)
        XCTAssertEqual(summary.remaining, 1)
    }

    func testExecuteMapsRpcError() async {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: [:],
                body: json([
                    "jsonrpc": "2.0", "id": 1,
                    "error": ["code": -32000, "message": "boom", "type": "ContractError"],
                ]))
        }
        let sdk = mero()
        do {
            let _: Int = try await sdk.rpc.execute(contextId: "ctx", method: "get")
            XCTFail("expected rpc error")
        } catch let error as MeroError {
            guard case .rpc(let e) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(e.code, -32000)
            XCTAssertEqual(e.message, "boom")
            XCTAssertEqual(e.type, "ContractError")
        } catch { XCTFail("wrong error type: \(error)") }
    }
}

// MARK: - Test helpers

final class CapturedBody: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

final class TokenTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var oldCount = 0
    func recordOld() { lock.lock(); oldCount += 1; lock.unlock() }
}
