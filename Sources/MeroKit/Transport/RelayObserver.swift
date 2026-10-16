import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Reading from a relay — because a relay is a node. Port of mero-js
// `src/transport/relay-observer.ts`.
//
// A relay serves `/auth/challenge`, `/auth/token`, `/sse` and `/ws` like any
// node, and the `account_proof` provider grants `context:subscribe` by
// default, so a keyholder can log in with its device certificate
// (``RelayLogin``) and observe. The one input that cannot be inferred is the
// relay's node signing key: the login statement names it, and it must never
// be read from the node being logged in to — whoever answered would choose
// what the device signs about. Nothing here invents a key.

/// How a relay-transport client observes the relay node. (== mero-js
/// `RelayObserveConfig`.)
///
/// Every field but ``nodeKey`` defaults to what the ``RelayClient`` already
/// holds: the author's proof, its device keys and the relay's own URL.
public struct RelayObserveConfig: Sendable {
    /// The relay node's Ed25519 signing key, 64 hex, **as this client pinned
    /// it**. `nil` means "nobody told me": ``MeroTransportClient/canSubscribe``
    /// is then `false`, and nothing guesses.
    public var nodeKey: String?
    /// The client surface the session is bound to (``LoginAudience/current``).
    public var audience: LoginAudience?
    /// The node to log in to; the relay's own URL by default.
    public var nodeURL: String?
    /// The author's `AccountProof<DeviceCert>`, hex; the relay client's by default.
    public var accountProof: String?
    /// The device keys; the relay client's by default — the same device
    /// authors and observes.
    public var keys: DeviceKeys?
    /// How this client names itself to the node.
    public var clientName: String?
    /// Seconds the login statement stays valid.
    public var ttlSeconds: UInt64?
    /// Per-request timeout for the login.
    public var timeout: TimeInterval?

    public init(
        nodeKey: String?, audience: LoginAudience? = nil, nodeURL: String? = nil, accountProof: String? = nil,
        keys: DeviceKeys? = nil, clientName: String? = nil, ttlSeconds: UInt64? = nil, timeout: TimeInterval? = nil
    ) {
        self.nodeKey = nodeKey
        self.audience = audience
        self.nodeURL = nodeURL
        self.accountProof = accountProof
        self.keys = keys
        self.clientName = clientName
        self.ttlSeconds = ttlSeconds
        self.timeout = timeout
    }
}

/// A node session over the relay, and the event clients it feeds.
/// (== mero-js `RelayObserver`.)
///
/// The session is minted lazily, on the first thing that needs a token:
/// reading ``events`` or ``ws`` sends nothing. Two surfaces asking at once
/// mint one session, and it is minted again once it is within
/// ``expirySkew`` of expiring — or on every ask when its lifetime cannot be
/// read, since an extra handshake costs less than a stream that stops.
public final class RelayObserver: @unchecked Sendable {
    /// Re-login this long before the access token expires.
    public static let expirySkew: TimeInterval = 30

    /// The node this observer logs in to.
    public let nodeURL: String
    /// The node key this observer logs in with.
    public let nodeKey: String
    private let session: URLSession
    private let minter: RelayTokenMinter
    private let lock = NSLock()
    private var sseConnection: SseConnection?
    private var wsClient: WsClient?

    /// - Parameters:
    ///   - nodeURL: the relay node.
    ///   - nodeKey: its signing key, pinned out of band.
    ///   - accountProof: the device certificate, hex.
    ///   - keys: the certified device's keys.
    ///   - now: the clock the token's expiry is read against (tests).
    public init(
        nodeURL: String, nodeKey: String, accountProof: String, keys: DeviceKeys,
        audience: LoginAudience = .current, clientName: String? = nil,
        ttlSeconds: UInt64 = RelayLogin.defaultTTLSeconds, timeout: TimeInterval = 10, session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        var trimmed = nodeURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let key = nodeKey.lowercased()
        let base = trimmed
        self.nodeURL = base
        self.nodeKey = key
        self.session = session
        let login: @Sendable () async throws -> TokenData = {
            try await RelayLogin.login(
                relayURL: base, nodeKey: key, credential: accountProof, keys: keys, audience: audience,
                clientName: clientName, ttlSeconds: ttlSeconds, session: session, timeout: timeout, now: now())
        }
        self.minter = RelayTokenMinter(now: now, skew: RelayObserver.expirySkew, login: login)
    }

    /// A usable access token, logging in if there is not one.
    public func accessToken() async throws -> String {
        try await minter.accessToken()
    }

    /// SSE over the relay node, fed by this observer's session. The same
    /// ``SseConnection`` every time, so handlers are not registered twice.
    public var events: SseConnection {
        lock.lock()
        defer { lock.unlock() }
        if let sseConnection { return sseConnection }
        let made = SseConnection(baseURL: baseURL, token: tokenProvider(), session: session)
        sseConnection = made
        return made
    }

    /// **Experimental** WebSocket events over the relay node. Prefer ``events``.
    public var ws: WsClient {
        lock.lock()
        defer { lock.unlock() }
        if let wsClient { return wsClient }
        let made = WsClient(baseURL: baseURL, token: tokenProvider())
        wsClient = made
        return made
    }

    /// Close whatever was opened. Never touches the relay's write path.
    public func close() {
        lock.lock()
        let sse = sseConnection
        let ws = wsClient
        lock.unlock()
        sse?.close()
        ws?.close()
    }

    private var baseURL: URL {
        // `nodeURL` was a relay URL the caller chose; a malformed one fails the
        // stream's first request rather than this getter.
        URL(string: nodeURL) ?? URL(fileURLWithPath: "/")
    }

    private func tokenProvider() -> @Sendable () async -> String? {
        let minter = self.minter
        return { try? await minter.accessToken() }
    }
}

/// Single-flight minting of an access token that is re-minted near expiry.
actor RelayTokenMinter {
    private let now: @Sendable () -> Date
    private let skew: TimeInterval
    private let login: @Sendable () async throws -> TokenData
    private var token: String?
    private var expiresAt: Date?
    private var pending: Task<TokenData, Error>?
    /// How many logins this minter has started (tests).
    private(set) var logins = 0

    init(
        now: @escaping @Sendable () -> Date, skew: TimeInterval,
        login: @escaping @Sendable () async throws -> TokenData
    ) {
        self.now = now
        self.skew = skew
        self.login = login
    }

    func accessToken() async throws -> String {
        if let token, let expiresAt, expiresAt.timeIntervalSince(now()) > skew {
            return token
        }
        if let pending {
            return try await pending.value.accessToken
        }
        logins += 1
        let task = Task { try await login() }
        pending = task
        defer { pending = nil }
        do {
            let minted = try await task.value
            token = minted.accessToken
            // An unreadable lifetime means "mint a fresh session" next time,
            // not "assume an hour".
            let exp = expiresAtFromJWT(minted.accessToken, fallback: .distantPast)
            expiresAt = exp == .distantPast ? nil : exp
            return minted.accessToken
        } catch {
            token = nil
            expiresAt = nil
            throw error
        }
    }
}
