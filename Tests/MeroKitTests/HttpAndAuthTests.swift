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
            Credentials(username: "alice", password: "pw", bootstrapSecret: "SECRET"))

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
        XCTAssertEqual(provider["bootstrap_secret"] as? String, "SECRET")
    }

    func testAuthenticateOmitsBootstrapWhenAbsent() async throws {
        let captured = CapturedBody()
        MockURLProtocol.setHandler { req in
            captured.value = bodyString(req)
            return .init(
                status: 200, headers: [:],
                body: json(["data": ["access_token": "A", "refresh_token": "R"]]))
        }
        let sdk = mero()
        _ = try await sdk.authenticate(Credentials(username: "bob", password: "pw"))
        let obj = try JSONSerialization.jsonObject(with: Data((captured.value ?? "").utf8)) as? [String: Any]
        let provider = obj?["provider_data"] as? [String: Any]
        XCTAssertNil(provider?["bootstrap_secret"])
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
