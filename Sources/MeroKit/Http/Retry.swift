import Foundation

/// Whether an error is worth retrying with backoff: network failures, timeouts,
/// and HTTP 5xx / 429. 4xx (incl. 401/403) and ``MeroError/authRevoked`` are not
/// retried. (== `defaultRetryCondition` in mero-js `retry.ts`.)
func isRetryable(_ error: Error) -> Bool {
    switch error {
    case MeroError.network:
        return true
    case MeroError.http(let e):
        return e.status >= 500 || e.status == 429
    case MeroError.authRevoked:
        return false
    default:
        // URLError timeouts / connection loss thrown before classification.
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// Exponential backoff with ±20% jitter. Base 250 ms. (== `calculateDelay` in `retry.ts`.)
/// `jitter` is injectable so tests are deterministic.
func backoffDelay(attempt: Int, jitter: Double = Double.random(in: -0.2...0.2)) -> TimeInterval {
    let base = 0.25
    let delay = base * pow(2.0, Double(attempt - 1))
    return max(0, delay + jitter * delay)
}

/// Run `fn`, retrying retryable failures with backoff up to `attempts` times.
/// (== `withRetry` in mero-js `retry.ts`.)
func withRetry<T: Sendable>(
    attempts: Int = 3,
    sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    },
    _ fn: @Sendable (_ attempt: Int) async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 1...max(1, attempts) {
        do {
            return try await fn(attempt)
        } catch {
            lastError = error
            let remaining = attempts - attempt
            if remaining <= 0 || !isRetryable(error) {
                throw error
            }
            try await sleep(backoffDelay(attempt: attempt))
        }
    }
    throw lastError ?? MeroError.network("Retry failed without error")
}

/// Transport callbacks the HTTP client uses to inject/refresh auth.
/// (== the `getAuthToken`/`refreshToken`/`onTokenRefresh`/`onAuthRevoked` hooks in mero-js.)
public struct TransportHooks: Sendable {
    /// Return the current access token to send as `Authorization: Bearer`.
    public var getAuthToken: (@Sendable () async -> String?)?
    /// Refresh on a 401 `token_expired`; returns the new access token (and should
    /// have already persisted the rotated bundle). Single-flighted by the caller.
    public var refreshToken: (@Sendable () async throws -> String)?
    /// Called once after a successful refresh with the new access token.
    public var onTokenRefresh: (@Sendable (String) async -> Void)?
    /// Called when the token family is gone (`x-auth-error: token_reuse|token_revoked`).
    public var onAuthRevoked: (@Sendable () async -> Void)?

    public init(
        getAuthToken: (@Sendable () async -> String?)? = nil,
        refreshToken: (@Sendable () async throws -> String)? = nil,
        onTokenRefresh: (@Sendable (String) async -> Void)? = nil,
        onAuthRevoked: (@Sendable () async -> Void)? = nil
    ) {
        self.getAuthToken = getAuthToken
        self.refreshToken = refreshToken
        self.onTokenRefresh = onTokenRefresh
        self.onAuthRevoked = onAuthRevoked
    }
}
