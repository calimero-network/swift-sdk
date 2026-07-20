import Foundation

/// Credentials for a direct `username`/`password` login (== mero-js `credentials`).
public struct Credentials: Sendable, Equatable {
    public var username: String
    public var password: String
    /// First-login setup code (bootstrap secret, core#3221). Since core
    /// 0.11.0-rc.14 a fresh node only mints its first root key when the login
    /// presents this out-of-band secret — merod prints it at startup and stores
    /// it in the node's config.toml (core#3270). Only consulted on the very
    /// first login of a fresh node; once an account exists the node ignores it,
    /// so it is always safe to include.
    public var bootstrapSecret: String?

    public init(username: String, password: String, bootstrapSecret: String? = nil) {
        self.username = username
        self.password = password
        self.bootstrapSecret = bootstrapSecret
    }
}

/// Configuration for a ``Mero`` instance.
public struct MeroConfig: Sendable {
    /// Base URL for the Calimero node (remote).
    public var baseURL: URL
    /// Initial credentials for authentication (optional).
    public var credentials: Credentials?
    /// Per-request timeout. Default 10s (matches mero-js `timeoutMs: 10000`).
    public var timeout: TimeInterval
    /// Optional token store for persistence. Defaults to an in-memory store.
    public var tokenStore: (any TokenStore)?

    public init(
        baseURL: URL,
        credentials: Credentials? = nil,
        timeout: TimeInterval = 10,
        tokenStore: (any TokenStore)? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.timeout = timeout
        self.tokenStore = tokenStore
    }
}

/// A token bundle: access + refresh token and the access token's expiry.
///
/// Persisted to a ``TokenStore`` verbatim. `expiresAt` is derived from the JWT
/// `exp` claim (see ``expiresAtFromJWT(_:fallback:)``).
public struct TokenData: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Access-token expiry. Informational only — the SDK never refreshes
    /// proactively (refresh is reactive on 401, per core's contract).
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        // Persisted as epoch milliseconds (matches mero-js `expires_at`).
        let ms = try c.decodeIfPresent(Double.self, forKey: .expiresAt) ?? 0
        expiresAt =
            ms > 0
            ? Date(timeIntervalSince1970: ms / 1000)
            : Date().addingTimeInterval(3600)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(refreshToken, forKey: .refreshToken)
        try c.encode(expiresAt.timeIntervalSince1970 * 1000, forKey: .expiresAt)
    }
}

/// Extract `exp` (seconds) from a JWT and return it as a `Date`, or `fallback`
/// if the token isn't a parseable JWT. (== mero-js `expiresAtFromJwt`.)
public func expiresAtFromJWT(_ token: String, fallback: Date) -> Date {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return fallback }

    // JWT uses base64url: map -/_ back to +// and pad to a multiple of 4.
    var b64 = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }

    guard
        let data = Data(base64Encoded: b64),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let exp = obj["exp"] as? Double
    else {
        return fallback
    }
    return Date(timeIntervalSince1970: exp)
}
