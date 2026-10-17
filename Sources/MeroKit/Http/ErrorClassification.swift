import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// What a failed request means, in terms a caller can act on.
// (== mero-js `errors/classify.ts`.)
//
// Core rc.56 onwards answers a refused admin request with the status that
// names the refusal: a malformed body is a 400, a caller the node will not
// serve a 403, a missing resource a 404, a state the request contradicts (an
// expired invitation, a removed member) a 409, an oversized upload a 413, and
// a request the node cannot serve *yet* (no member online to hand over a group
// key) a 503. Every caller asks the same two questions of such an error: what
// kind of failure is this, and would doing it again later help? This answers
// both once, so apps stop keeping their own copies of the status table.

/// The kind of failure, as far as it decides what the caller does next.
/// Raw values are mero-js's `ErrorKind` strings.
public enum ErrorKind: String, Sendable, Equatable, CaseIterable {
    /// 400 (or another 4xx). The request is wrong; sending it again cannot help.
    case invalid
    /// 401. This client's session lapsed; signing in again can finish it.
    case unauthorized
    /// 403. The node will not do this for this caller.
    case forbidden
    /// 404. What the request names does not exist on this node (yet).
    case notFound = "not-found"
    /// 409. The request contradicts the current state: expired, spent, removed.
    case conflict
    /// 410. It existed and is gone for good.
    case gone
    /// 413. The body is over the node's limit.
    case tooLarge = "too-large"
    /// 429. The node asked the caller to slow down.
    case rateLimited = "rate-limited"
    /// 503 or 504. The node cannot serve this yet — no peer online, say.
    case unavailable
    /// Any other 5xx. The node failed; the request may well have been fine.
    case server
    /// Status 0 / a transport failure. The request never reached the node:
    /// offline, DNS, a timeout.
    case unreachable
    /// Not an HTTP failure, or one with nothing more specific to go on.
    case unknown

    /// Whether a failure of this kind could succeed later without anything
    /// changing on the caller's side. (== mero-js `RETRYABLE`.)
    public var isRetryable: Bool {
        switch self {
        case .invalid, .forbidden, .conflict, .gone, .tooLarge:
            return false
        // `unauthorized`: the session, not the request — sign in again and repeat it.
        // `notFound`: too broad to give up on; the resource may not have synced yet.
        case .unauthorized, .notFound, .rateLimited, .unavailable, .server, .unreachable, .unknown:
            return true
        }
    }

    /// The kind an HTTP status names. (== mero-js `kindForStatus`.)
    public init(status: Int) {
        switch status {
        case 0: self = .unreachable
        case 400: self = .invalid
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        case 409: self = .conflict
        case 410: self = .gone
        case 413: self = .tooLarge
        case 429: self = .rateLimited
        case 503, 504: self = .unavailable
        case 500..<600: self = .server
        case 400..<500: self = .invalid
        default: self = .unknown
        }
    }
}

/// What a failed request means. (== mero-js `ClassifiedError`.)
public struct ClassifiedError: Sendable, Equatable {
    public let kind: ErrorKind
    /// The HTTP status, when the error carries one. `0` means no response
    /// arrived (``MeroError/network(_:)``).
    public let status: Int?
    /// Whether the same request could succeed later without anything changing
    /// on the caller's side. False for a refusal the node chose — asking again
    /// gets the same answer — and true for a failure about the moment.
    public let retryable: Bool
    /// The node's own explanation, without an `HTTP <status>` prefix, falling
    /// back to the error's description. For logs and for a UI that shows
    /// detail; a UI that wants friendly copy should switch on ``kind``.
    public let message: String

    public init(kind: ErrorKind, status: Int?, retryable: Bool, message: String) {
        self.kind = kind
        self.status = status
        self.retryable = retryable
        self.message = message
    }

    init(kind: ErrorKind, status: Int?, message: String) {
        self.init(kind: kind, status: status, retryable: kind.isRetryable, message: message)
    }
}

extension HTTPError {
    /// The node's explanation of the failure: the body's `error` string (or
    /// `error.message`, or FastAPI's `detail`, which the Cloud manager sends),
    /// or for status 0 the transport's own text. `nil` when there is none.
    /// (== mero-js `HTTPError.explanation`.)
    public var explanation: String? {
        if let bodyText, let bytes = bodyText.data(using: .utf8),
            case .object(let obj)? = try? JSONDecoder().decode(JSONValue.self, from: bytes)
        {
            if case .string(let error)? = obj["error"], !error.trimmingCharacters(in: .whitespaces).isEmpty {
                return error
            }
            if case .object(let nested)? = obj["error"], case .string(let message)? = nested["message"],
                !message.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return message
            }
            if case .string(let detail)? = obj["detail"], !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                return detail
            }
        }
        if status == 0, let text = bodyText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return nil
    }
}

/// What a failed request means: its kind, whether a later attempt could work,
/// and the node's own words for it. (== mero-js `classifyError`.)
///
/// Accepts anything a `catch` hands over:
///
/// - ``MeroError/http(_:)`` and ``MeroError/authRevoked(reason:http:)`` (and a
///   bare ``HTTPError``) by status — a revoked family is a `401`/`403` like
///   any other.
/// - ``MeroError/network(_:)`` is ``ErrorKind/unreachable`` with status `0`,
///   as mero-js's status-0 `HTTPError`; a raw `URLError` is `unreachable`
///   with no status (a cancelled one is ``ErrorKind/unknown``).
/// - ``AccountError``: a refusal that carries a status (`intentRefused`,
///   `haRefused`) by that status, the rest by what they mean — a malformed
///   input or an unverifiable credential is ``ErrorKind/invalid``, a declined
///   enrolment or link ``ErrorKind/forbidden``, a missing session
///   ``ErrorKind/unauthorized``, an unestablished relay key, an invitation
///   nobody can claim yet or a cloud account not ready to write
///   ``ErrorKind/unavailable``.
/// - Everything else (``MeroError/rpc(_:)``, decoding failures, …) is
///   ``ErrorKind/unknown`` and retryable, with its description.
public func classifyError(_ error: Error) -> ClassifiedError {
    switch error {
    case let error as MeroError:
        return classify(error)
    case let http as HTTPError:
        return classify(http)
    case let account as AccountError:
        return classify(account)
    case let urlError as URLError:
        let kind: ErrorKind = urlError.code == .cancelled ? .unknown : .unreachable
        return ClassifiedError(kind: kind, status: nil, message: errorText(urlError))
    default:
        return ClassifiedError(kind: .unknown, status: nil, message: errorText(error))
    }
}

private func classify(_ http: HTTPError) -> ClassifiedError {
    ClassifiedError(
        kind: ErrorKind(status: http.status), status: http.status, message: http.explanation ?? http.message)
}

private func classify(_ error: MeroError) -> ClassifiedError {
    switch error {
    case .http(let http):
        return classify(http)
    case .authRevoked(_, let http):
        return ClassifiedError(
            kind: ErrorKind(status: http.status), status: http.status,
            message: http.explanation ?? errorText(error))
    case .network(let message):
        return ClassifiedError(kind: .unreachable, status: 0, message: message.isEmpty ? errorText(error) : message)
    case .rpc(let rpc):
        let message = rpc.message.isEmpty ? errorText(error) : rpc.message
        return ClassifiedError(kind: .unknown, status: nil, message: message)
    case .emptyResponse, .authenticationFailed, .noCredentials, .noRefreshToken, .decoding:
        return ClassifiedError(kind: .unknown, status: nil, message: errorText(error))
    }
}

private func classify(_ error: AccountError) -> ClassifiedError {
    let message = errorText(error)
    switch error {
    case .intentRefused(let reason, let retryable, let status):
        let kind = ErrorKind(status: status)
        // A nonce refusal is one recovery can fix, whatever its status says.
        return ClassifiedError(
            kind: kind, status: status, retryable: kind.isRetryable || retryable,
            message: reason.isEmpty ? message : reason)
    case .haRefused(_, let status, _):
        return ClassifiedError(kind: ErrorKind(status: status), status: status, message: message)
    case .invalidInput, .credentialRejected, .stateMismatch, .protocolViolation:
        return ClassifiedError(kind: .invalid, status: nil, message: message)
    case .enrolmentDeclined, .linkDeclined, .notForAccount:
        return ClassifiedError(kind: .forbidden, status: nil, message: message)
    case .notSignedIn:
        return ClassifiedError(kind: .unauthorized, status: nil, message: message)
    case .relayKeyUnavailable, .invitationNotClaimable, .cloudNotReady, .noRelay:
        return ClassifiedError(kind: .unavailable, status: nil, message: message)
    }
}

/// The most specific description an error carries. (== mero-js `messageOf` fallback.)
private func errorText(_ error: Error) -> String {
    if let text = (error as? LocalizedError)?.errorDescription, !text.trimmingCharacters(in: .whitespaces).isEmpty {
        return text
    }
    let text = error.localizedDescription
    return text.trimmingCharacters(in: .whitespaces).isEmpty ? "Request failed" : text
}
