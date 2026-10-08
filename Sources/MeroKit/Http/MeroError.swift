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

// MARK: - Typed refusals (core rc.83)

/// The JSON body core sends with a refusal: `{"error": "...", "type": "...", "data": ...}`.
///
/// Since core 0.11.0-rc.83 most refusals carry a precise status (400, 403,
/// 404, 409, 503) instead of a blanket 500, and method errors from
/// `/contexts/{id}/query` and `/contexts/{id}/intents` add `type` (e.g.
/// `"FunctionCallError"`) and `data`, the same pair JSON-RPC errors carry.
public struct ErrorRefusal: Sendable, Equatable {
    /// The `error` string, when the body had one.
    public let message: String?
    /// The `type` tag, when the body had one.
    public let type: String?
    /// The `data` payload, when the body had one.
    public let data: JSONValue?

    public init(message: String? = nil, type: String? = nil, data: JSONValue? = nil) {
        self.message = message
        self.type = type
        self.data = data
    }
}

extension HTTPError {
    /// The refusal parsed from ``bodyText``, or `nil` when the body is not a
    /// JSON object with any of `error`, `type` or `data`.
    public var refusal: ErrorRefusal? {
        guard let bodyText, let bytes = bodyText.data(using: .utf8),
            case .object(let obj)? = try? JSONDecoder().decode(JSONValue.self, from: bytes)
        else { return nil }
        var message: String?
        if case .string(let m)? = obj["error"] { message = m }
        var type: String?
        if case .string(let t)? = obj["type"] { type = t }
        let data = obj["data"]
        if message == nil, type == nil, data == nil { return nil }
        return ErrorRefusal(message: message, type: type, data: data)
    }
}

extension MeroError {
    /// The HTTP status, for the cases that carry one.
    public var httpStatus: Int? {
        switch self {
        case .http(let e): return e.status
        case .authRevoked(_, let e): return e.status
        default: return nil
        }
    }

    /// The typed refusal body, for an HTTP failure that carried one.
    public var refusal: ErrorRefusal? {
        switch self {
        case .http(let e): return e.refusal
        case .authRevoked(_, let e): return e.refusal
        default: return nil
        }
    }

    /// The JSON-RPC error's `type` tag (`"ReadOnlyWriteRefused"`,
    /// `"FunctionCallError"`, ...), or the HTTP refusal's `type`.
    public var errorType: String? {
        switch self {
        case .rpc(let e): return e.type
        default: return refusal?.type
        }
    }
}

extension RpcError {
    /// The `type` core uses when this node's role (`ReadOnly`, `ReadOnlyTee`
    /// or `RelayTee`) means a write it ran would be discarded. New in rc.83.
    public static let readOnlyWriteRefusedType = "ReadOnlyWriteRefused"

    /// Whether the node refused a write because it only holds a read-only
    /// replica of the context. Retrying here never helps: send the write to a
    /// node with a writing role, or as an intent through a relay.
    public var isReadOnlyWriteRefused: Bool { type == Self.readOnlyWriteRefusedType }

    /// The context a ``isReadOnlyWriteRefused`` refusal names, from
    /// `data.context_id`.
    public var refusedContextId: String? {
        guard isReadOnlyWriteRefused, case .object(let obj)? = data, case .string(let id)? = obj["context_id"]
        else { return nil }
        return id
    }
}
