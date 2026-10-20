import Foundation

/// Why a username/password login (``Mero/authenticate(_:)``) failed, typed, so
/// an app can answer each case differently: ask again for a wrong password,
/// count down a lockout, point at the URL for a missing node.
///
/// Build one from whatever the login threw with ``init(_:)``.
public enum LoginFailureReason: Sendable, Equatable {
    /// The node refused the username or password (a `4xx` about the credentials).
    case invalidCredentials
    /// Too many failed attempts: the node locked logins out for a while
    /// (`429`). `retryAfter` is the node's `Retry-After`, in seconds, when it
    /// sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Nothing answered: no network, DNS, a refused connection, a timeout.
    case unreachable
    /// Something answered, but has no login there (`404`): usually a wrong URL.
    case notFound
    /// The node failed (`5xx`).
    case serverError(status: Int)
    /// Anything else (an undecodable answer, say).
    case other

    /// Classify an error thrown by a login.
    public init(_ error: Error) {
        switch error {
        case MeroError.authenticationFailed, MeroError.noCredentials:
            self = .invalidCredentials
        case MeroError.network:
            self = .unreachable
        case MeroError.http(let http):
            self = Self.classify(http)
        case MeroError.authRevoked(_, let http):
            self = Self.classify(http)
        case is URLError:
            self = .unreachable
        default:
            self = .other
        }
    }

    private static func classify(_ http: HTTPError) -> LoginFailureReason {
        switch http.status {
        case 429:
            return .rateLimited(retryAfter: http.headers["retry-after"].flatMap(Self.retryAfter))
        case 404:
            return .notFound
        case 500...:
            return .serverError(status: http.status)
        case 400..<500:
            return .invalidCredentials
        default:
            return .other
        }
    }

    /// `Retry-After` as seconds (core sends seconds; an HTTP date is read too).
    static func retryAfter(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
