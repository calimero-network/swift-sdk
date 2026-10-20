import Foundation

/// Top-level MeroKit SDK object (== mero-js `MeroJs`).
///
/// Modeled as an `actor` so token state and single-flight refresh are race-free
/// by construction — the Swift analog of mero-js's `refreshPromise` + Web Lock.
/// Talks to a **remote** Calimero node; there is no embedded node on device.
public actor Mero {
    private let config: MeroConfig
    private let tokenStore: any TokenStore
    private let session: URLSession
    /// The node a token bundle is bound to (``TokenData/nodeKey(for:)``).
    private let nodeKey: String
    /// Live SSE streams this instance started, cancelled by ``close()``.
    private let streams = SseStreamRegistry()
    /// The shared ``sse`` and ``ws`` clients, made on first use.
    private let shared = SharedEventClients()

    private var tokenData: TokenData?
    /// In-flight refresh, shared by concurrent 401s in this instance
    /// (== mero-js `refreshPromise`).
    private var refreshTask: Task<TokenData, Error>?

    private lazy var httpClient: URLSessionHttpClient = {
        let hooks = TransportHooks(
            getAuthToken: { [weak self] in await self?.currentAccessToken() },
            refreshToken: { [weak self] in
                guard let self else { throw MeroError.noRefreshToken }
                return try await self.performTokenRefresh().accessToken
            },
            onAuthRevoked: { [weak self] in await self?.clearToken() },
            getProof: proofCallback,
            authorizeRequest: proofAuthorizer
        )
        return URLSessionHttpClient(
            baseURL: config.baseURL,
            timeout: config.timeout,
            hooks: hooks,
            session: session
        )
    }()

    public init(config: MeroConfig) {
        self.init(config: config, session: .shared)
    }

    /// The ``MeroConfig/requestProof`` signer, resolved once at construction.
    private let proofCallback: ProofCallback?
    private let proofAuthorizer: RequestAuthorizer?

    /// Designated initializer allowing a custom `URLSession` (used by tests to
    /// inject a `MockURLProtocol`-backed session).
    public init(config: MeroConfig, session: URLSession) {
        self.config = config
        self.tokenStore = config.tokenStore ?? MemoryTokenStore()
        self.session = session
        self.nodeKey = TokenData.nodeKey(for: config.baseURL)
        switch config.requestProof {
        case .none:
            proofCallback = nil
            proofAuthorizer = nil
        case .keys(let options):
            // A key that cannot sign is reported on the first request instead,
            // since `init` does not throw.
            let signer = Result { try createProofSigner(options) }
            proofCallback = { request in try await signer.get()(request) }
            proofAuthorizer = nil
        case .custom(let callback):
            proofCallback = callback
            proofAuthorizer = nil
        case .authorizer(let authorizer):
            proofCallback = nil
            proofAuthorizer = authorizer
        }
        // Restore tokens from the store if this node issued them.
        self.tokenData = Self.boundTokens(in: self.tokenStore, nodeKey: self.nodeKey)
    }

    // MARK: - Sub-clients

    public var auth: AuthApi { AuthApi(http: httpClient) }
    public var admin: AdminApi { AdminApi(http: httpClient) }
    public var rpc: RpcClient { RpcClient(http: httpClient) }

    /// Live node events for the given contexts, over SSE (auto-reconnecting).
    /// Cancel the consuming task, or call ``close()``, to close the stream.
    /// Powers push updates (new messages, etc.) without polling. `nonisolated` —
    /// reads only the immutable config and defers the token read to the async
    /// provider.
    ///
    /// `groupIds` (core rc.83) also subscribes to group-keyed events — membership
    /// changes and migration progress — which arrive with
    /// ``ContextEvent/groupId`` set. ``groupEvents(groupIds:)`` and
    /// ``nodeEvents(contextIds:groupIds:)`` deliver those typed instead.
    public nonisolated func events(
        contextIds: [String], groupIds: [String] = []
    ) -> AsyncThrowingStream<ContextEvent, Error> {
        sseClient().events(contextIds: contextIds, groupIds: groupIds)
    }

    /// Group-keyed events (membership changes, migration progress) for
    /// `groupIds`, over the same auto-reconnecting SSE as
    /// ``events(contextIds:groupIds:)``. The node silently drops ids the
    /// token may not observe. (== Kotlin `Mero.groupEvents`.)
    public nonisolated func groupEvents(groupIds: [String]) -> AsyncThrowingStream<GroupEvent, Error> {
        sseClient().groupEvents(groupIds: groupIds)
    }

    /// Context and group events on one stream, subscribed together on every
    /// (re)connect. (== Kotlin `Mero.nodeEvents`.)
    public nonisolated func nodeEvents(
        contextIds: [String], groupIds: [String]
    ) -> AsyncThrowingStream<NodeEvent, Error> {
        sseClient().nodeEvents(contextIds: contextIds, groupIds: groupIds)
    }

    /// `AppVersionChanged` events of `contextIds`, parsed, on their own
    /// auto-reconnecting stream. (== mero-js `onAppVersionChanged`.)
    public nonisolated func appVersionChanges(
        contextIds: [String]
    ) -> AsyncThrowingStream<AppVersionChangedEvent, Error> {
        sseClient().appVersionChanges(contextIds: contextIds)
    }

    /// Migration events of `groupIds` (namespace roots), typed, on their own
    /// auto-reconnecting stream. (== mero-js `onMigrationEvent`.)
    public nonisolated func migrationEvents(groupIds: [String]) -> AsyncThrowingStream<GroupMigrationEvent, Error> {
        sseClient().migrationEvents(groupIds: groupIds)
    }

    /// This instance's one long-lived SSE connection (== mero-js
    /// `MeroJs.events`): subscribe and unsubscribe ids while it runs, read
    /// typed streams off it, and let presence share it. Not connected until
    /// ``SseConnection/connect()`` (or a presence subscription) asks.
    /// ``close()`` closes it.
    public nonisolated var sse: SseConnection {
        shared.sse { sseClient().connection() }
    }

    /// **Experimental** WebSocket event client (== mero-js `MeroJs.ws`,
    /// `@experimental` there too). Prefer ``sse``. ``close()`` closes it.
    public nonisolated var ws: WsClient {
        shared.ws { WsClient(baseURL: config.baseURL, token: tokenProvider()) }
    }

    /// Ephemeral presence over ``rpc`` (`set_ephemeral`) and ``sse``.
    /// (== mero-js `MeroJs.ephemeral`.)
    public var ephemeral: EphemeralClient {
        EphemeralClient(rpc: rpc, events: sse)
    }

    private nonisolated func tokenProvider() -> @Sendable () async -> String? {
        { [weak self] in await self?.currentTokenData()?.accessToken }
    }

    private nonisolated func sseClient() -> SseClient {
        SseClient(baseURL: config.baseURL, token: tokenProvider(), session: session, registry: streams)
    }

    /// The transport in use (for advanced/custom callers).
    public var http: any HttpClient { httpClient }

    // MARK: - Authentication

    /// Authenticate with credentials, creating the root key on first use.
    /// Builds the exact mero-js `/auth/token` body.
    @discardableResult
    public func authenticate(_ credentials: Credentials? = nil) async throws -> TokenData {
        guard let creds = credentials ?? config.credentials else {
            throw MeroError.noCredentials
        }

        let providerData: [String: JSONValue] = [
            "username": .string(creds.username),
            "password": .string(creds.password),
        ]

        let request = TokenRequest(
            authMethod: "user_password",
            publicKey: creds.username,
            clientName: "mero-swift-sdk",
            permissions: ["admin"],
            timestamp: Int(Date().timeIntervalSince1970),
            providerData: providerData
        )

        do {
            let response = try await auth.generateTokens(request)
            let accessToken = response.data.accessToken
            let bundle = TokenData(
                accessToken: accessToken,
                refreshToken: response.data.refreshToken,
                expiresAt: expiresAtFromJWT(accessToken, fallback: Date().addingTimeInterval(3600))
            )
            self.tokenData = bundle
            persistTokens()
            return bundle
        } catch let error as MeroError {
            // Only the node REFUSING the credentials means the credentials are
            // wrong. Flattening every failure into `authenticationFailed` told
            // the caller to check its password when the node was unreachable or
            // broken — and that mislabel is what let the sample app's e2e sit
            // pointed at a nonexistent host for five weeks, reported as
            // "check your username and password".
            //
            // So: a 4xx that is about authentication becomes
            // `authenticationFailed`. Everything else stays what it is, and the
            // caller can tell "wrong password" from "no node there". A `429`
            // (logins locked out after failed attempts, with `Retry-After`) and
            // a `404` (no login at that URL) are not about the credentials
            // either, and stay `.http` — see ``LoginFailureReason``.
            switch error {
            case .http(let http) where http.status == 429 || http.status == 404:
                throw error
            case .http(let http) where (400..<500).contains(http.status):
                throw MeroError.authenticationFailed(error.localizedDescription)
            case .http, .network, .decoding, .authRevoked, .emptyResponse, .rpc,
                .authenticationFailed, .noCredentials, .noRefreshToken:
                throw error
            }
        } catch let error as URLError {
            throw MeroError.network(error.localizedDescription)
        } catch {
            throw MeroError.authenticationFailed(error.localizedDescription)
        }
    }

    /// Current access token as-is. The SDK never refreshes proactively — the
    /// server rejects refresh while the access token is still valid, so refresh
    /// is driven reactively by the HTTP 401 path. (== mero-js `getValidToken`.)
    private func currentAccessToken() -> String? {
        tokenData?.accessToken
    }

    /// Single-flight token refresh. Every caller (including the transport's 401
    /// hook) funnels through here.
    ///
    /// Refresh tokens are single-use (core#3083): each refresh consumes the
    /// presented token and returns a new one; replaying a consumed token makes
    /// the server revoke the whole family. This actor serializes access, an
    /// in-flight `Task` dedupes concurrent 401s, and a re-read of the store
    /// inside the refresh adopts a bundle another process already rotated.
    private func performTokenRefresh() async throws -> TokenData {
        if let refreshTask {
            return try await refreshTask.value
        }
        let triggering = tokenData?.accessToken
        let task = Task { try await self.performTokenRefreshLocked(triggering: triggering) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performTokenRefreshLocked(triggering: String?) async throws -> TokenData {
        // Another process/extension may have rotated the bundle — the store, not
        // our in-memory copy, is the source of truth. Only a bundle this node
        // issued: another node's tokens must never be presented here.
        if let stored = Self.boundTokens(in: tokenStore, nodeKey: nodeKey) {
            tokenData = stored
            if let triggering, stored.accessToken != triggering {
                // Someone else already refreshed. Adopt their bundle rather than
                // replaying our now-consumed refresh token (which revokes the family).
                return stored
            }
        }

        guard let current = tokenData, !current.refreshToken.isEmpty else {
            throw MeroError.noRefreshToken
        }

        do {
            let response = try await auth.refreshToken(
                RefreshTokenRequest(accessToken: current.accessToken, refreshToken: current.refreshToken)
            )
            let accessToken = response.data.accessToken
            let bundle = TokenData(
                accessToken: accessToken,
                // The refresh token rotates on every refresh — persist the new one
                // or the next refresh replays a consumed token.
                refreshToken: response.data.refreshToken,
                expiresAt: expiresAtFromJWT(accessToken, fallback: Date().addingTimeInterval(3600))
            )
            tokenData = bundle
            persistTokens()
            return bundle
        } catch {
            // Do NOT clear tokens on a non-terminal refresh failure — the access
            // token may still be valid. Only `authRevoked` (handled by the
            // transport's onAuthRevoked hook) clears the bundle.
            throw MeroError.authenticationFailed("Token refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Token state

    /// Write the bundle to the store, tagged with the node that issued it.
    private func persistTokens() {
        guard var bundle = tokenData else { return }
        bundle.nodeOrigin = nodeKey
        tokenStore.setTokens(bundle)
    }

    /// The stored bundle, only if `nodeKey` issued it. A bundle for another
    /// node — or one persisted before bundles named their node — reads as
    /// empty, so its tokens are never sent here. (== mero-js `readStoredTokens`.)
    private static func boundTokens(in store: any TokenStore, nodeKey: String) -> TokenData? {
        guard var stored = store.getTokens(), stored.nodeOrigin == nodeKey else { return nil }
        stored.nodeOrigin = nil
        return stored
    }

    /// Whether a token bundle is present.
    public var isAuthenticated: Bool { tokenData != nil }

    /// The current token bundle (for debugging / persistence handoff).
    public func currentTokenData() -> TokenData? { tokenData }

    /// Set token data directly (e.g. from an SSO callback). If `expiresAt` is the
    /// distant past/unset, derives it from the JWT `exp` claim (fallback now+1h).
    ///
    /// The bundle is bound to this instance's node: whatever ``TokenData/nodeOrigin``
    /// `data` carries, the stored copy names this node.
    public func setTokenData(_ data: TokenData) {
        var bundle = data
        bundle.nodeOrigin = nil
        if bundle.expiresAt <= Date(timeIntervalSince1970: 0) {
            bundle.expiresAt = expiresAtFromJWT(bundle.accessToken, fallback: Date().addingTimeInterval(3600))
        }
        tokenData = bundle
        persistTokens()
    }

    /// Set token data from a parsed SSO callback.
    public func setTokenData(from callback: AuthCallbackResult) {
        setTokenData(
            TokenData(
                accessToken: callback.accessToken,
                refreshToken: callback.refreshToken,
                expiresAt: expiresAtFromJWT(callback.accessToken, fallback: Date().addingTimeInterval(3600))
            ))
    }

    /// Drop the token bundle and clear the store. (== mero-js `clearToken`.)
    public func clearToken() {
        refreshTask?.cancel()
        refreshTask = nil
        tokenData = nil
        tokenStore.clear()
    }

    /// Log out: retire the refresh token on the node, then clear tokens locally
    /// and release resources.
    ///
    /// The server half (`POST /auth/logout`, new in core rc.83) is best-effort:
    /// an unreachable node, an older node without the route, or a token the
    /// node already refuses never stops the local clear, so a caller is always
    /// logged out on this device. Mirrors mero-react's `logout` (clear the
    /// store even when never connected, so tokens don't linger).
    public func logout() async {
        let bundle = tokenData ?? Self.boundTokens(in: tokenStore, nodeKey: nodeKey)
        if let refreshToken = bundle?.refreshToken, !refreshToken.isEmpty {
            // A bare transport: no bearer, no 401-refresh, no revoke hook. A
            // refresh triggered from inside logout would consume the very token
            // being retired.
            let bare = URLSessionHttpClient(baseURL: config.baseURL, timeout: config.timeout, session: session)
            _ = try? await AuthApi(http: bare).logout(LogoutRequest(refreshToken: refreshToken))
        }
        clearToken()
        close()
    }

    /// Close every live event stream this instance started
    /// (``events(contextIds:groupIds:)``, ``groupEvents(groupIds:)``,
    /// ``nodeEvents(contextIds:groupIds:)`` and the typed ones), and the
    /// shared ``sse`` and ``ws`` clients: each connection is cancelled and its
    /// `for try await` loops end normally. Streams opened afterwards work as
    /// usual. (== mero-js `close`.)
    public func close() {
        streams.cancelAll()
        shared.closeAll()
    }

    // MARK: - SSO utilities (static)

    /// Parse an SSO callback — `nil` unless it answers a login begun with
    /// ``buildAuthLoginUrl(nodeUrl:options:stateStore:)`` on the same
    /// `stateStore`. See ``SsoLogin/parseAuthCallback(_:options:stateStore:)``.
    public static func parseAuthCallback(
        _ url: String,
        options: ParseAuthCallbackOptions = ParseAuthCallbackOptions(),
        stateStore: AuthLoginStateStore = .shared
    ) -> AuthCallbackResult? {
        SsoLogin.parseAuthCallback(url, options: options, stateStore: stateStore)
    }

    /// Build the hosted-SSO login URL, beginning a login in `stateStore`.
    /// See ``SsoLogin/buildAuthLoginUrl(nodeUrl:options:stateStore:)``.
    public static func buildAuthLoginUrl(
        nodeUrl: String, options: AuthLoginOptions, stateStore: AuthLoginStateStore = .shared
    ) -> String {
        SsoLogin.buildAuthLoginUrl(nodeUrl: nodeUrl, options: options, stateStore: stateStore)
    }
}

/// The lazily made, shared event clients of one ``Mero``. Thread-safe.
final class SharedEventClients: @unchecked Sendable {
    private let lock = NSLock()
    private var sseConnection: SseConnection?
    private var wsClient: WsClient?

    func sse(_ make: () -> SseConnection) -> SseConnection {
        lock.lock()
        defer { lock.unlock() }
        if let sseConnection { return sseConnection }
        let made = make()
        sseConnection = made
        return made
    }

    func ws(_ make: () -> WsClient) -> WsClient {
        lock.lock()
        defer { lock.unlock() }
        if let wsClient { return wsClient }
        let made = make()
        wsClient = made
        return made
    }

    /// Close both, keeping them for reuse (each may ``SseConnection/connect()`` again).
    func closeAll() {
        lock.lock()
        let sse = sseConnection
        let ws = wsClient
        lock.unlock()
        sse?.close()
        ws?.close()
    }
}
