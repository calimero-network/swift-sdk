import Foundation
import MeroKit

/// Which node an SSO callback may authenticate against. Port of mero-react
/// `auth/node-trust.ts`.
///
/// The node's login page sends the person back with `access_token`,
/// `refresh_token` and `node_url` in the callback URL. That URL is
/// attacker-influenceable: a hostile `node_url` would otherwise have the app
/// send freshly minted tokens to the attacker's node. So a callback is only
/// trusted against a node the app chose itself — the one the login was started
/// with, or one on an app-configured allowlist.
public enum NodeTrust {
    /// The decision for one callback. (== mero-react `TrustedNodeResult`.)
    public struct TrustedNode: Sendable, Equatable {
        /// The node it is safe to authenticate against, or `nil`.
        public let url: String?
        /// A `node_url` was present but could not be trusted (likely an attack).
        public let rejected: Bool

        public init(url: String?, rejected: Bool) {
            self.url = url
            self.rejected = rejected
        }
    }

    /// `scheme://host[:port]`, lowercased, with the scheme's default port
    /// dropped — what a browser calls the URL's origin. `nil` if it does not parse.
    public static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        if let port = components.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Both URLs parse and share an origin (scheme, host and port).
    /// (== mero-react `sameOrigin`.)
    public static func sameOrigin(_ a: String, _ b: String) -> Bool {
        guard let left = origin(of: a), let right = origin(of: b) else { return false }
        return left == right
    }

    /// Decide which node, if any, is safe to authenticate against.
    /// (== mero-react `resolveTrustedNodeUrl`.)
    ///
    /// - No candidate: the initiated node.
    /// - Candidate and an initiated node: it must share that node's origin.
    /// - Candidate, no initiated node, an allowlist: it must be on the list.
    /// - Candidate and no trust anchor at all: rejected.
    public static func resolveTrustedNodeURL(
        candidate: String?, initiated: String?, allowedNodeURLs: [String] = []
    ) -> TrustedNode {
        guard let candidate, !candidate.isEmpty else { return TrustedNode(url: initiated, rejected: false) }
        if let initiated, !initiated.isEmpty {
            return sameOrigin(candidate, initiated)
                ? TrustedNode(url: candidate, rejected: false) : TrustedNode(url: nil, rejected: true)
        }
        if !allowedNodeURLs.isEmpty {
            return allowedNodeURLs.contains { sameOrigin(candidate, $0) }
                ? TrustedNode(url: candidate, rejected: false) : TrustedNode(url: nil, rejected: true)
        }
        return TrustedNode(url: nil, rejected: true)
    }
}

/// Whether the token bundle an SSO callback carries may replace the stored
/// one. Port of mero-react `auth/token-adoption.ts`.
///
/// Refresh tokens are single-use since core 0.11.0: writing a callback's bundle
/// over one the SDK has already rotated resurrects a consumed refresh token,
/// the next refresh presents it, and the node revokes the whole token family
/// (`token_reuse`). So the callback's bundle is adopted only when there is no
/// stored bundle, the node changed, the callback's tokens are genuinely newer,
/// or the stored bundle lacks a refresh token the callback can supply.
public enum TokenAdoption {
    /// The ordering claims of a JWT, read without verifying it.
    public struct Claims: Sendable, Equatable {
        /// Issued-at, seconds.
        public let iat: Double?
        /// Expiry, seconds.
        public let exp: Double?
    }

    /// Why a bundle was, or was not, adopted. Raw values are mero-react's.
    public enum Reason: String, Sendable, Equatable {
        case freshLogin = "fresh-login"
        case nodeChanged = "node-changed"
        case newer
        case fillRefresh = "fill-refresh"
        case stale
    }

    /// What to write to the token store, if anything.
    public enum Decision: Sendable, Equatable {
        case adopt(TokenData, Reason)
        case ignore

        public var tokens: TokenData? {
            if case .adopt(let tokens, _) = self { return tokens }
            return nil
        }

        public var reason: Reason {
            if case .adopt(_, let reason) = self { return reason }
            return .stale
        }
    }

    /// The `iat`/`exp` of a three-part JWT, or `nil` for anything else.
    /// (== mero-react `decodeJwtClaims`.)
    public static func decodeClaims(_ token: String) -> Claims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func positive(_ key: String) -> Double? {
            guard let value = payload[key] as? Double, value > 0 else { return nil }
            return value
        }
        return Claims(iat: positive("iat"), exp: positive("exp"))
    }

    /// Whether the callback's access token is newer than the stored one: `iat`
    /// first, then `exp`, then the stored bundle's recorded expiry. Unknown is
    /// not newer.
    static func isNewer(_ incomingToken: String, than stored: TokenData) -> Bool {
        guard let incoming = decodeClaims(incomingToken) else { return false }
        if let current = decodeClaims(stored.accessToken) {
            if let a = incoming.iat, let b = current.iat, a != b { return a > b }
            if let a = incoming.exp, let b = current.exp, a != b { return a > b }
            return false
        }
        guard let exp = incoming.exp else { return false }
        return exp > stored.expiresAt.timeIntervalSince1970
    }

    /// Decide what to write for an SSO callback. (== mero-react `resolveTokenAdoption`.)
    ///
    /// Never returns a bundle with an empty refresh token while one for the same
    /// node is stored: an access-only callback is merged over the stored bundle.
    public static func resolve(
        callbackAccessToken: String, callbackRefreshToken: String, callbackNodeURL: String,
        stored: TokenData?, storedNodeURL: String?, now: Date = Date()
    ) -> Decision {
        func bundle(_ refresh: String) -> TokenData {
            TokenData(
                accessToken: callbackAccessToken, refreshToken: refresh,
                expiresAt: expiresAtFromJWT(callbackAccessToken, fallback: now.addingTimeInterval(3600)))
        }
        guard let stored, !stored.accessToken.isEmpty else {
            return .adopt(bundle(callbackRefreshToken), .freshLogin)
        }
        let sameNode = storedNodeURL.map { NodeTrust.sameOrigin(callbackNodeURL, $0) } ?? false
        guard sameNode else { return .adopt(bundle(callbackRefreshToken), .nodeChanged) }
        let refresh = callbackRefreshToken.isEmpty ? stored.refreshToken : callbackRefreshToken
        if isNewer(callbackAccessToken, than: stored) { return .adopt(bundle(refresh), .newer) }
        if stored.refreshToken.isEmpty, !callbackRefreshToken.isEmpty {
            var filled = stored
            filled.refreshToken = callbackRefreshToken
            return .adopt(filled, .fillRefresh)
        }
        return .ignore
    }
}
