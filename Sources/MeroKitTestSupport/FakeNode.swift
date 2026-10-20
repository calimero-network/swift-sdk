import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stateful, in-memory fake Calimero node backed by ``MockURLProtocol`` — the
/// Swift analog of nock / msw. Model a whole login → call → refresh → logout
/// journey without a live node.
///
/// Beyond auth and JSON-RPC it keeps the state an app's own tests usually
/// need, in core's wire shapes: scoped client keys (`POST /admin/client-key`),
/// contexts, installed applications, blobs (raw bytes) and group / member /
/// context metadata. Seed it with ``addApplication(id:package:version:)``,
/// ``addContext(id:applicationId:groupId:)`` and ``putBlob(_:)``. And
/// ``goOffline(_:)`` fails every request at the transport, as a phone with no
/// network does.
///
/// Thread-safe: the URLProtocol handler runs on arbitrary threads.
public final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()

    // Rotating token state.
    private var version = 0
    public private(set) var accessToken = ""
    public private(set) var refreshToken = ""
    private var accessExpired = false
    /// Refresh tokens already consumed — replaying one revokes the family.
    private var consumedRefreshTokens: Set<String> = []
    private var familyRevoked = false

    // Call counters, for assertions.
    public private(set) var tokenCalls = 0
    public private(set) var refreshCalls = 0
    public private(set) var rpcCalls = 0
    public private(set) var protectedCalls = 0
    public private(set) var logoutCalls = 0
    /// The refresh token the last `/auth/logout` presented.
    public private(set) var lastLoggedOutRefreshToken: String?

    /// Canned contract output for `/jsonrpc`, keyed by method.
    public var rpcOutputs: [String: Any] = ["get": 42]

    /// Per-protected-call response delays, consumed in arrival order (missing
    /// entries mean no delay).
    ///
    /// The auth check still happens when the request arrives, so a call that
    /// presented a now-stale token is judged 401 at t=0 and *delivered* later —
    /// the shape needed to land a 401 after a concurrent refresh has already
    /// rotated the bundle.
    private var protectedDelays: [TimeInterval] = []

    /// Delay the Nth protected response by `delays[N]` seconds.
    public func delayProtectedResponses(_ delays: [TimeInterval]) {
        lock.lock(); protectedDelays = delays; lock.unlock()
    }

    // Admin state (contexts, applications, blobs, metadata, client keys).
    private var counter = 0
    private var contextOrder: [String] = []
    private var contextRecords: [String: [String: Any]] = [:]
    private var applicationOrder: [String] = []
    private var applicationRecords: [String: [String: Any]] = [:]
    private var blobOrder: [String] = []
    private var blobStore: [String: Data] = [:]
    private var metadataRecords: [String: [String: Any]] = [:]
    private var clientKeyRecords: [MintedClientKey] = []
    private var offlineCode: URLError.Code?

    /// A client key minted through `POST /admin/client-key`: what was asked
    /// for, and the tokens handed back (which the node then accepts).
    public struct MintedClientKey: Sendable, Equatable {
        public let contextId: String?
        public let contextIdentity: String?
        public let applicationId: String?
        public let permissions: [String]
        public let accessToken: String
        public let refreshToken: String
    }

    public init() {}

    /// Route every request on `MockURLProtocol` through this node.
    public func install() {
        MockURLProtocol.setHandler { [weak self] req in
            self?.handle(req) ?? .init(status: 500, headers: [:], body: Data())
        }
    }

    // MARK: - Test controls

    /// Simulate the access token expiring — the next protected call returns
    /// `401 token_expired`, driving a reactive refresh.
    public func expireAccessToken() {
        lock.lock(); accessExpired = true; lock.unlock()
    }

    /// Simulate the whole family being revoked — protected calls return
    /// `401 token_reuse` (terminal).
    public func revokeFamily() {
        lock.lock(); familyRevoked = true; lock.unlock()
    }

    /// Fail every request with `code` before it reaches the node — no HTTP
    /// response at all (``MockURLProtocol/Stub/transportError(_:delay:)``).
    /// Through ``MeroKit`` it surfaces as `MeroError.network`.
    public func goOffline(_ code: URLError.Code = .notConnectedToInternet) {
        lock.lock(); offlineCode = code; lock.unlock()
    }

    /// Undo ``goOffline(_:)``. The node's state is as it was.
    public func goOnline() {
        lock.lock(); offlineCode = nil; lock.unlock()
    }

    // MARK: - Seeding and inspection

    /// Install an application, as `GET /admin-api/applications` lists it.
    public func addApplication(
        id: String, package: String = "com.example.app", version: String = "1.0.0", signerId: String = "signer"
    ) {
        let record: [String: Any] = [
            "id": id, "blob": ["bytecode": "bytecode-\(id)", "compiled": "compiled-\(id)"], "size": 0,
            "source": "fake://\(package)/\(version)", "metadata": [Int](), "signer_id": signerId,
            "package": package, "version": version,
        ]
        lock.lock()
        if applicationRecords[id] == nil { applicationOrder.append(id) }
        applicationRecords[id] = record
        lock.unlock()
    }

    /// Add a context the node already holds.
    public func addContext(id: String, applicationId: String, groupId: String? = nil) {
        lock.lock()
        insertContext(id: id, applicationId: applicationId, groupId: groupId)
        lock.unlock()
    }

    /// Store `data` as a blob and return its id, as an upload would.
    @discardableResult
    public func putBlob(_ data: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        return storeBlob(data)
    }

    /// The bytes of blob `id`, exactly as stored, or `nil`.
    public func blob(_ id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return blobStore[id]
    }

    /// The ids of the contexts the node holds, oldest first.
    public var contextIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return contextOrder
    }

    /// Every client key minted so far, oldest first.
    public var clientKeys: [MintedClientKey] {
        lock.lock(); defer { lock.unlock() }
        return clientKeyRecords
    }

    // MARK: - Counters

    private func bump(_ keyPath: ReferenceWritableKeyPath<FakeNode, Int>) {
        lock.lock(); self[keyPath: keyPath] += 1; lock.unlock()
    }

    // MARK: - Routing

    private func handle(_ req: URLRequest) -> MockURLProtocol.Stub {
        let path = req.url?.path ?? ""
        let method = req.httpMethod ?? "GET"

        lock.lock()
        let offline = offlineCode
        lock.unlock()
        if let offline { return .transportError(offline) }

        switch (method, path) {
        case ("POST", "/auth/token"):
            return issueTokens(req)
        case ("POST", "/auth/refresh"):
            return refresh(req)
        case ("POST", "/auth/logout"):
            return logout(req)
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
            return guarded(req) { self.listContexts(forApplication: nil) }
        case ("POST", "/admin-api/contexts"):
            return guarded(req) { self.createContext(req) }
        case ("GET", "/admin-api/applications"):
            return guarded(req) { self.listApplications() }
        case ("PUT", "/admin-api/blobs"):
            return guarded(req) { self.uploadBlob(req) }
        case ("GET", "/admin-api/blobs"):
            return guarded(req) { self.listBlobs() }
        case ("POST", "/admin/client-key"):
            return guarded(req) { self.mintClientKey(req) }
        case ("POST", "/jsonrpc"):
            return guarded(req) { self.jsonrpc(req) }
        default:
            return routeByPrefix(req, method: method, path: path)
        }
    }

    /// The routes with an id in the path.
    private func routeByPrefix(_ req: URLRequest, method: String, path: String) -> MockURLProtocol.Stub {
        let forApp = "/admin-api/contexts/for-application/"
        if method == "GET", path.hasPrefix(forApp) {
            let app = String(path.dropFirst(forApp.count))
            return guarded(req) { self.listContexts(forApplication: app) }
        }
        if path.hasPrefix("/admin-api/groups/"), path.hasSuffix("/metadata") {
            switch method {
            case "PUT": return guarded(req) { self.setMetadata(req, key: path) }
            case "GET": return guarded(req) { self.getMetadata(key: path) }
            default: break
            }
        }
        if let id = Self.lastSegment(path, under: "/admin-api/contexts/") {
            switch method {
            case "GET": return guarded(req) { self.getContext(id) }
            case "DELETE": return guarded(req) { self.deleteContext(id) }
            default: break
            }
        }
        if method == "GET", let id = Self.lastSegment(path, under: "/admin-api/applications/") {
            return guarded(req) { self.getApplication(id) }
        }
        if let id = Self.lastSegment(path, under: "/admin-api/blobs/") {
            switch method {
            case "GET": return guarded(req) { self.getBlob(id, head: false) }
            case "HEAD": return guarded(req) { self.getBlob(id, head: true) }
            case "DELETE": return guarded(req) { self.deleteBlob(id) }
            default: break
            }
        }
        return .init(status: 404, headers: [:], body: Data())
    }

    /// The one segment after `prefix`, or `nil` when there is none or more.
    private static func lastSegment(_ path: String, under prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        return rest.isEmpty || rest.contains("/") ? nil : rest
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

    /// `POST /auth/logout` (core rc.83): retire the presented refresh token, so
    /// a later refresh with it is a replay.
    private func logout(_ req: URLRequest) -> MockURLProtocol.Stub {
        bump(\.logoutCalls)
        let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
        let presented = body?["refresh_token"] as? String ?? ""
        lock.lock()
        lastLoggedOutRefreshToken = presented
        consumedRefreshTokens.insert(presented)
        lock.unlock()
        return ok(["data": ["success": true]])
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

    // MARK: - Client keys

    /// `POST /admin/client-key`: a token pair scoped as asked, which the node
    /// accepts from then on. (`TokenResponse` shape, as `/auth/token`.)
    private func mintClientKey(_ req: URLRequest) -> MockURLProtocol.Stub {
        let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any] ?? [:]
        lock.lock()
        counter += 1
        let key = MintedClientKey(
            contextId: body["context_id"] as? String, contextIdentity: body["context_identity"] as? String,
            applicationId: body["application_id"] as? String, permissions: body["permissions"] as? [String] ?? [],
            accessToken: "client-access-\(counter)", refreshToken: "client-refresh-\(counter)")
        clientKeyRecords.append(key)
        lock.unlock()
        return ok(["data": ["access_token": key.accessToken, "refresh_token": key.refreshToken]])
    }

    // MARK: - Contexts

    /// Caller holds `lock`.
    private func insertContext(id: String, applicationId: String, groupId: String?) {
        var record: [String: Any] = [
            "id": id, "applicationId": applicationId, "contextStateHash": "hash-\(id)", "dagHeads": [[Int]](),
        ]
        if let groupId { record["groupId"] = groupId }
        if contextRecords[id] == nil { contextOrder.append(id) }
        contextRecords[id] = record
    }

    private func listContexts(forApplication app: String?) -> MockURLProtocol.Stub {
        lock.lock()
        let all = contextOrder.compactMap { contextRecords[$0] }
        lock.unlock()
        let contexts = app.map { app in all.filter { $0["applicationId"] as? String == app } } ?? all
        return ok(["data": ["contexts": contexts]])
    }

    private func createContext(_ req: URLRequest) -> MockURLProtocol.Stub {
        let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any] ?? [:]
        guard let app = body["applicationId"] as? String, !app.isEmpty else {
            return refusal(400, "applicationId is required")
        }
        let groupId = body["groupId"] as? String
        lock.lock()
        counter += 1
        let id = "context-\(counter)"
        insertContext(id: id, applicationId: app, groupId: groupId)
        let member = "member-\(counter)"
        lock.unlock()
        var data: [String: Any] = ["contextId": id, "memberPublicKey": member]
        if let groupId { data["groupId"] = groupId }
        return ok(["data": data])
    }

    private func getContext(_ id: String) -> MockURLProtocol.Stub {
        lock.lock()
        let record = contextRecords[id]
        lock.unlock()
        guard var record else { return refusal(404, "context not found") }
        record["groupId"] = nil
        return ok(["data": record])
    }

    private func deleteContext(_ id: String) -> MockURLProtocol.Stub {
        lock.lock()
        let existed = contextRecords.removeValue(forKey: id) != nil
        contextOrder.removeAll { $0 == id }
        lock.unlock()
        return ok(["data": ["isDeleted": existed]])
    }

    // MARK: - Applications

    private func listApplications() -> MockURLProtocol.Stub {
        lock.lock()
        let apps = applicationOrder.compactMap { applicationRecords[$0] }
        lock.unlock()
        return ok(["data": ["apps": apps]])
    }

    private func getApplication(_ id: String) -> MockURLProtocol.Stub {
        lock.lock()
        let app = applicationRecords[id]
        lock.unlock()
        return ok(["data": ["application": (app as Any?) ?? NSNull()]])
    }

    // MARK: - Blobs

    /// Caller holds `lock`.
    private func storeBlob(_ data: Data) -> String {
        counter += 1
        let id = "blob-\(counter)"
        blobOrder.append(id)
        blobStore[id] = data
        return id
    }

    /// `PUT /admin-api/blobs`: the raw body, byte for byte, is the blob.
    private func uploadBlob(_ req: URLRequest) -> MockURLProtocol.Stub {
        let bytes = FakeNode.body(req)
        lock.lock()
        let id = storeBlob(bytes)
        lock.unlock()
        return ok(["data": ["blob_id": id, "size": bytes.count]])
    }

    private func listBlobs() -> MockURLProtocol.Stub {
        lock.lock()
        let blobs = blobOrder.compactMap { id in
            blobStore[id].map { ["blob_id": id, "size": $0.count] as [String: Any] }
        }
        lock.unlock()
        return ok(["data": ["blobs": blobs]])
    }

    /// `GET` streams the bytes; `HEAD` answers the same headers and no body.
    private func getBlob(_ id: String, head: Bool) -> MockURLProtocol.Stub {
        lock.lock()
        let bytes = blobStore[id]
        lock.unlock()
        guard let bytes else { return .init(status: 404, headers: [:], body: Data()) }
        let headers = [
            "Content-Type": "application/octet-stream", "Content-Length": "\(bytes.count)", "X-Blob-Id": id,
            "X-Blob-Source": "local", "X-Blob-Mime-Type": "application/octet-stream",
        ]
        return .init(status: 200, headers: headers, body: head ? Data() : bytes)
    }

    /// Core's delete answers a flat `{ blob_id, deleted }`, no envelope.
    private func deleteBlob(_ id: String) -> MockURLProtocol.Stub {
        lock.lock()
        let existed = blobStore.removeValue(forKey: id) != nil
        blobOrder.removeAll { $0 == id }
        lock.unlock()
        return ok(["blob_id": id, "deleted": existed])
    }

    // MARK: - Metadata (group, member, context)

    /// `PUT …/metadata` replaces the record's `data`; an omitted `name` keeps
    /// the current one.
    private func setMetadata(_ req: URLRequest, key: String) -> MockURLProtocol.Stub {
        let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any] ?? [:]
        lock.lock()
        let previous = metadataRecords[key]
        var record: [String: Any] = [
            "data": body["data"] as? [String: String] ?? [:],
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000), "updatedBy": "fake-node",
        ]
        if let name = (body["name"] as? String) ?? (previous?["name"] as? String) { record["name"] = name }
        metadataRecords[key] = record
        lock.unlock()
        return .init(status: 200, headers: [:], body: Data())
    }

    /// `{ data: record }`, or `{ data: null }` before anything was set.
    private func getMetadata(key: String) -> MockURLProtocol.Stub {
        lock.lock()
        let record = metadataRecords[key]
        lock.unlock()
        return ok(["data": (record as Any?) ?? NSNull()])
    }

    // MARK: - Auth guard

    /// Run `handler` only if the bearer token is currently valid; otherwise a 401.
    private func guarded(_ req: URLRequest, _ handler: () -> MockURLProtocol.Stub) -> MockURLProtocol.Stub {
        bump(\.protectedCalls)
        lock.lock()
        let index = protectedCalls - 1
        let delay = index < protectedDelays.count ? protectedDelays[index] : 0
        lock.unlock()
        let stub = authError(req).map { unauthorized($0) } ?? handler()
        guard delay > 0 else { return stub }
        return .init(status: stub.status, headers: stub.headers, body: stub.body, delay: delay)
    }

    /// Returns the `x-auth-error` reason if the request's bearer is not valid, else nil.
    private func authError(_ req: URLRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        if familyRevoked { return "token_reuse" }
        let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
        if clientKeyRecords.contains(where: { bearer == "Bearer \($0.accessToken)" }) { return nil }
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

    private func refusal(_ status: Int, _ message: String) -> MockURLProtocol.Stub {
        .init(
            status: status, headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data())
    }

    private func unauthorized(_ reason: String) -> MockURLProtocol.Stub {
        .init(status: 401, headers: ["x-auth-error": reason], body: Data())
    }

    public static func body(_ req: URLRequest) -> Data {
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
