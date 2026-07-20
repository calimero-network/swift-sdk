import Foundation

/// Errors thrown across MeroKit. Mirrors the mero-js error surface
/// (`HTTPError`, `AuthRevokedError`, `RpcError`) plus a few Swift-specific cases.
public enum MeroError: Error, Sendable {
    /// A non-2xx HTTP response. `body` is capped at ~64 KiB.
    case http(HTTPError)

    /// The refresh-token family was revoked (single-use refresh token replayed,
    /// or the token was explicitly revoked). Terminal: never retried, never
    /// refreshed. Apps should catch this and force a re-login.
    ///
    /// Carries the underlying ``HTTPError`` so existing HTTP handling keeps working.
    case authRevoked(reason: String, http: HTTPError)

    /// A JSON-RPC error payload (`{ code, message, type, data }`).
    case rpc(RpcError)

    /// A transport-level failure (DNS, connection reset, timeout) with no HTTP status.
    case network(String)

    /// The server returned a 2xx with an empty or `null` `data` field where one
    /// was required. Message names the endpoint. (== mero-js's `throw new Error('... data is null')`.)
    case emptyResponse(String)

    /// Authentication failed (wrapping the underlying cause). (== mero-js `Authentication failed: ...`.)
    case authenticationFailed(String)

    /// No credentials were supplied to `authenticate`.
    case noCredentials

    /// No refresh token is available to perform a refresh.
    case noRefreshToken

    /// A response body could not be decoded into the expected type.
    case decoding(String)
}

extension MeroError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let e):
            return e.message
        case .authRevoked(let reason, let e):
            return "Authentication revoked (\(reason)): HTTP \(e.status) \(e.statusText)"
        case .rpc(let e):
            return "RPC error \(e.code): \(e.message)"
        case .network(let m):
            return "Network error: \(m)"
        case .emptyResponse(let m):
            return m
        case .authenticationFailed(let m):
            return "Authentication failed: \(m)"
        case .noCredentials:
            return "No credentials provided for authentication"
        case .noRefreshToken:
            return "No refresh token available"
        case .decoding(let m):
            return "Failed to decode response: \(m)"
        }
    }
}

/// A non-2xx HTTP response. Header names are lowercased.
public struct HTTPError: Error, Sendable, Equatable {
    public let status: Int
    public let statusText: String
    public let url: String
    public let headers: [String: String]
    /// Response body text, capped at ~64 KiB.
    public let bodyText: String?

    public init(status: Int, statusText: String, url: String, headers: [String: String], bodyText: String? = nil) {
        self.status = status
        self.statusText = statusText
        self.url = url
        self.headers = headers
        self.bodyText = bodyText
    }

    public var message: String { "HTTP \(status) \(statusText)" }
}

/// A JSON-RPC 2.0 error object. (== mero-js `RpcError`.)
public struct RpcError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let type: String?
    public let data: JSONValue?

    public init(code: Int, message: String, type: String? = nil, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.type = type
        self.data = data
    }
}
