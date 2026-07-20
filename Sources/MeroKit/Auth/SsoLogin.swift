import Foundation

/// Tokens + context ids parsed from an SSO callback URL's hash fragment.
/// (== mero-js `AuthCallbackResult`.)
public struct AuthCallbackResult: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let applicationId: String
    public let contextId: String
    public let contextIdentity: String
    public let nodeUrl: String
}

/// Options for building the hosted-SSO login URL. (== mero-js `AuthLoginOptions`.)
public struct AuthLoginOptions: Sendable {
    public var callbackUrl: String
    public var packageName: String?
    public var mode: String
    public var permissions: [String]?
    public var registryUrl: String?
    public var packageVersion: String?

    public init(
        callbackUrl: String,
        mode: String,
        packageName: String? = nil,
        permissions: [String]? = nil,
        registryUrl: String? = nil,
        packageVersion: String? = nil
    ) {
        self.callbackUrl = callbackUrl
        self.mode = mode
        self.packageName = packageName
        self.permissions = permissions
        self.registryUrl = registryUrl
        self.packageVersion = packageVersion
    }
}

public enum SsoLogin {
    /// Parse tokens from the hash fragment of an SSO callback URL.
    /// Returns `nil` if `access_token` is absent. Byte-for-byte compatible with
    /// mero-js `parseAuthCallback` (the node emits the same fragment for web and mobile).
    public static func parseAuthCallback(_ url: String) -> AuthCallbackResult? {
        guard let hashIndex = url.firstIndex(of: "#") else { return nil }
        let fragment = String(url[url.index(after: hashIndex)...])
        let params = parseQuery(fragment)

        guard let accessToken = params["access_token"], !accessToken.isEmpty else { return nil }

        return AuthCallbackResult(
            accessToken: accessToken,
            refreshToken: params["refresh_token"] ?? "",
            applicationId: params["application_id"] ?? "",
            contextId: params["context_id"] ?? "",
            contextIdentity: params["context_identity"] ?? "",
            nodeUrl: params["node_url"] ?? ""
        )
    }

    /// Build the node auth login URL to open in `ASWebAuthenticationSession`.
    /// (== mero-js `buildAuthLoginUrl`.)
    public static func buildAuthLoginUrl(nodeUrl: String, options: AuthLoginOptions) -> String {
        var items: [URLQueryItem] = []
        items.append(URLQueryItem(name: "callback-url", value: options.callbackUrl))

        if let permissions = options.permissions, !permissions.isEmpty {
            items.append(URLQueryItem(name: "permissions", value: permissions.joined(separator: ",")))
        }

        items.append(URLQueryItem(name: "mode", value: options.mode))

        if let packageName = options.packageName {
            items.append(URLQueryItem(name: "package-name", value: packageName))
            if let packageVersion = options.packageVersion {
                items.append(URLQueryItem(name: "package-version", value: packageVersion))
            }
            if let registryUrl = options.registryUrl {
                items.append(URLQueryItem(name: "registry-url", value: registryUrl))
            }
        }

        // Trim trailing slashes from nodeUrl.
        var base = nodeUrl
        while base.hasSuffix("/") { base.removeLast() }

        var comps = URLComponents()
        comps.queryItems = items
        let query = comps.percentEncodedQuery ?? ""
        return "\(base)/auth/login?\(query)"
    }

    /// Parse an `application/x-www-form-urlencoded` string (as `URLSearchParams` does).
    private static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(kv[0])
            let rawValue = kv.count > 1 ? String(kv[1]) : ""
            let key = formDecode(rawKey)
            let value = formDecode(rawValue)
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    private static func formDecode(_ s: String) -> String {
        // `URLSearchParams` decodes '+' to space, then percent-decodes.
        let plussed = s.replacingOccurrences(of: "+", with: " ")
        return plussed.removingPercentEncoding ?? plussed
    }
}
