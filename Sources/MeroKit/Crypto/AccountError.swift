import Foundation

/// Errors the app layer raises itself, before or instead of asking a node.
/// Refusals a node answered are ``CalimeroError``s.
public enum AccountError: Error, Equatable, Sendable {
    /// An input was malformed before anything was sent (wrong hex width, JSON
    /// that does not parse, …). Nothing was spent.
    case invalidInput(String)

    /// A node answered with something this client cannot use.
    case protocolViolation(String)

    /// The operation needs a signed-in session that is absent.
    case notSignedIn(String)

    /// Nothing serves `method`: the app is signed out, so there is no node
    /// session to run it on. Sign in first. (The name predates Calimero 1.0,
    /// when a hosted relay ran an account's calls.)
    case noRelay(method: String)
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return m
        case .protocolViolation(let m): return m
        case .notSignedIn(let m): return m
        case .noRelay(let method): return "\(method) needs a signed-in session: sign in first"
        }
    }
}
