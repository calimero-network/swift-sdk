import Foundation

@testable import MeroKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stateful, in-memory fake Calimero node backed by ``MockURLProtocol`` — the
/// Swift analog of nock / msw. Model a whole login → call → refresh → logout
/// journey without a live node.
///
/// Thread-safe: the URLProtocol handler runs on arbitrary threads.
final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()

    // Rotating token state.
    private var version = 0
    private(set) var accessToken = ""
    private(set) var refreshToken = ""
    private var accessExpired = false
    /// Refresh tokens already consumed — replaying one revokes the family.
    private var consumedRefreshTokens: Set<String> = []
    private var familyRevoked = false

    // Call counters, for assertions.
    private(set) var tokenCalls = 0
    private(set) var refreshCalls = 0
    private(set) var rpcCalls = 0
    private(set) var protectedCalls = 0

    // Canned contract output for `/jsonrpc`, keyed by method.
    var rpcOutputs: [String: Any] = ["get": 42]

    init() {}

    /// Route every request on `MockURLProtocol` through this node.
    func install() {
        MockURLProtocol.setHandler { [weak self] req in
            self?.handle(req) ?? .init(status: 500, headers: [:], body: Data())
        }
    }

    // MARK: - Test controls

    /// Simulate the access token expiring — the next protected call returns
    /// `401 token_expired`, driving a reactive refresh.
    func expireAccessToken() {
        lock.lock(); accessExpired = true; lock.unlock()
    }

    /// Simulate the whole family being revoked — protected calls return
    /// `401 token_reuse` (terminal).
    func revokeFamily() {
        lock.lock(); familyRevoked = true; lock.unlock()
    }

    // MARK: - Counters (locked reads)

    private func bump(_ keyPath: ReferenceWritableKeyPath<FakeNode, Int>) {
        lock.lock(); self[keyPath: keyPath] += 1; lock.unlock()
    }

    // MARK: - Routing

    private func handle(_ req: URLRequest) -> MockURLProtocol.Stub {
        let path = req.url?.path ?? ""
        let method = req.httpMethod ?? "GET"

        switch (method, path) {
        case ("POST", "/auth/token"):
            return issueTokens(req)
        case ("POST", "/auth/refresh"):
            return refresh(req)
        case ("HEAD", "/auth/validate"):
            return validate(req)
        case ("GET", "/auth/health"):
            return ok(["data": ["status": "alive", "storage": true, "uptime_seconds": 1]])
        case ("GET", "/auth/providers"):
            return ok([
                "data": [
                    "providers": [
                        [
                            "name": "user_password", "type": "password",
                            "description": "dev", "configured": true, "config": [:],
                        ]
                    ],
                    "count": 1,
                ]
            ])
        case ("GET", "/admin/identity"):
            return ok([
                "data": [
                    "service": "mero-auth", "version": "test",
                    "authentication_mode": "embedded", "providers": ["user_password"],
                ]
            ])
        case ("GET", "/admin-api/contexts"):
            return guarded(req) { self.ok(["data": ["contexts": []]]) }
        case ("POST", "/jsonrpc"):
            return guarded(req) { self.jsonrpc(req) }
        default:
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    // MARK: - Handlers

    private func issueTokens(_ req: URLRequest) -> MockURLProtocol.Stub {
        bump(\.tokenCalls)
        lock.lock()
        version += 1
        accessToken = "access-\(version)"
        refreshToken = "refresh-\(version)"
        accessExpired = false
        familyRevoked = false
        let access = accessToken
        let refresh = refreshToken
        lock.unlock()
        return ok(["data": ["access_token": access, "refresh_token": refresh]])
    }

    private func refresh(_ req: URLRequest) -> MockURLProtocol.Stub {
        bump(\.refreshCalls)
        let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
        let presented = body?["refresh_token"] as? String ?? ""

        lock.lock()
        // Single-use: replaying a consumed refresh token revokes the family.
        if consumedRefreshTokens.contains(presented) || presented != refreshToken {
            familyRevoked = true
            lock.unlock()
            return unauthorized("token_reuse")
        }
        consumedRefreshTokens.insert(presented)
        version += 1
        accessToken = "access-\(version)"
        refreshToken = "refresh-\(version)"
        accessExpired = false
        let access = accessToken
        let refresh = refreshToken
        lock.unlock()
        return ok(["data": ["access_token": access, "refresh_token": refresh]])
    }

    private func validate(_ req: URLRequest) -> MockURLProtocol.Stub {
        if authError(req) != nil { return .init(status: 401, headers: [:], body: Data()) }
        return .init(status: 200, headers: [:], body: Data())
    }

    private func jsonrpc(_ req: URLRequest) -> MockURLProtocol.Stub {
        bump(\.rpcCalls)
        let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
        let params = body?["params"] as? [String: Any]
        let methodName = params?["method"] as? String ?? ""
        let output = rpcOutputs[methodName] ?? rpcOutputs["get"] ?? 0
        return ok(["jsonrpc": "2.0", "id": 1, "result": ["output": output]])
    }

    // MARK: - Auth guard

    /// Run `handler` only if the bearer token is currently valid; otherwise a 401.
    private func guarded(_ req: URLRequest, _ handler: () -> MockURLProtocol.Stub) -> MockURLProtocol.Stub {
        bump(\.protectedCalls)
        if let reason = authError(req) { return unauthorized(reason) }
        return handler()
    }

    /// Returns the `x-auth-error` reason if the request's bearer is not valid, else nil.
    private func authError(_ req: URLRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        if familyRevoked { return "token_reuse" }
        let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
        if bearer != "Bearer \(accessToken)" { return "token_expired" }
        if accessExpired { return "token_expired" }
        return nil
    }

    // MARK: - Response helpers

    private func ok(_ dict: [String: Any]) -> MockURLProtocol.Stub {
        .init(
            status: 200, headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data())
    }

    private func unauthorized(_ reason: String) -> MockURLProtocol.Stub {
        .init(status: 401, headers: ["x-auth-error": reason], body: Data())
    }

    static func body(_ req: URLRequest) -> Data {
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
