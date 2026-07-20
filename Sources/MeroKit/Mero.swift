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
            onAuthRevoked: { [weak self] in await self?.clearToken() }
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

    /// Designated initializer allowing a custom `URLSession` (used by tests to
    /// inject a `MockURLProtocol`-backed session).
    public init(config: MeroConfig, session: URLSession) {
        self.config = config
        self.tokenStore = config.tokenStore ?? MemoryTokenStore()
        self.session = session
        // Restore tokens from the store if present.
        self.tokenData = self.tokenStore.getTokens()
    }

    // MARK: - Sub-clients

    public var auth: AuthApi { AuthApi(http: httpClient) }
    public var admin: AdminApi { AdminApi(http: httpClient) }
    public var rpc: RpcClient { RpcClient(http: httpClient) }

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

        // First-login setup code (core#3221): explicit credential wins; there is
        // no env fallback on iOS. Omitted entirely when absent, making the request
        // byte-identical to the pre-rc.14 shape.
        var providerData: [String: JSONValue] = [
            "username": .string(creds.username),
            "password": .string(creds.password),
        ]
        if let secret = creds.bootstrapSecret, !secret.isEmpty {
            providerData["bootstrap_secret"] = .string(secret)
        }

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
            tokenStore.setTokens(bundle)
            return bundle
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
        // our in-memory copy, is the source of truth.
        if let stored = tokenStore.getTokens() {
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
            tokenStore.setTokens(bundle)
            return bundle
        } catch {
            // Do NOT clear tokens on a non-terminal refresh failure — the access
            // token may still be valid. Only `authRevoked` (handled by the
            // transport's onAuthRevoked hook) clears the bundle.
            throw MeroError.authenticationFailed("Token refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Token state

    /// Whether a token bundle is present.
    public var isAuthenticated: Bool { tokenData != nil }

    /// The current token bundle (for debugging / persistence handoff).
    public func currentTokenData() -> TokenData? { tokenData }

    /// Set token data directly (e.g. from an SSO callback). If `expiresAt` is the
    /// distant past/unset, derives it from the JWT `exp` claim (fallback now+1h).
    public func setTokenData(_ data: TokenData) {
        var bundle = data
        if bundle.expiresAt <= Date(timeIntervalSince1970: 0) {
            bundle.expiresAt = expiresAtFromJWT(bundle.accessToken, fallback: Date().addingTimeInterval(3600))
        }
        tokenData = bundle
        tokenStore.setTokens(bundle)
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

    /// Log out: clear tokens locally and release resources. Mirrors mero-react's
    /// `logout` (clear the store even when never connected, so tokens don't linger).
    public func logout() {
        clearToken()
        close()
    }

    /// Close any long-lived connections (events, etc.). No-op until events land.
    public func close() {
        // SSE/WS clients (roadmap M3) will be torn down here.
    }

    // MARK: - SSO utilities (static)

    public static func parseAuthCallback(_ url: String) -> AuthCallbackResult? {
        SsoLogin.parseAuthCallback(url)
    }

    public static func buildAuthLoginUrl(nodeUrl: String, options: AuthLoginOptions) -> String {
        SsoLogin.buildAuthLoginUrl(nodeUrl: nodeUrl, options: options)
    }
}
