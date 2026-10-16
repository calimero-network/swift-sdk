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

/// Options for ``SsoLogin/parseAuthCallback(_:options:stateStore:)``.
/// (== mero-js `ParseAuthCallbackOptions`.)
public struct ParseAuthCallbackOptions: Sendable, Equatable {
    /// Accept tokens this app did not ask for, for a host that injects them
    /// itself. Anyone who can open the app's URL can then choose the session,
    /// so leave it `false` unless the URL can only come from a trusted host.
    public var allowUnsolicited: Bool

    public init(allowUnsolicited: Bool = false) {
        self.allowUnsolicited = allowUnsolicited
    }
}

/// The pending logins ``SsoLogin/buildAuthLoginUrl(nodeUrl:options:stateStore:)``
/// began: each `auth_state` and when it expires, in epoch milliseconds.
public struct PendingAuthLogins: Codable, Sendable, Equatable {
    public var expiries: [String: Double]

    public init(expiries: [String: Double] = [:]) {
        self.expiries = expiries
    }
}

/// Logins this app began, so an SSO callback can be matched to one.
/// (== the `calimero.auth.login.pending` store of mero-js `link-state.ts`.)
///
/// Anyone can hand the app a URL with tokens of their choosing in the
/// fragment; adopting them would sign the person in to the sender's node and
/// account. So ``SsoLogin/buildAuthLoginUrl(nodeUrl:options:stateStore:)``
/// records a fresh random state here and puts it in the callback URL, and
/// ``SsoLogin/parseAuthCallback(_:options:stateStore:)`` accepts a callback
/// only if it carries a state that is still pending — once (single use), and
/// within ``defaultLifetime``.
///
/// The default, ``shared``, is in memory: a login begun and finished in one
/// launch (the `ASWebAuthenticationSession` case). Use ``keychain(account:service:accessGroup:)``
/// when the callback can arrive in a later launch, or from an extension.
public final class AuthLoginStateStore: @unchecked Sendable {
    /// How long a begun login stays answerable: 10 minutes (as mero-js).
    public static let defaultLifetime: TimeInterval = 10 * 60
    /// Logins kept at once; older ones are dropped (as mero-js `MAX_PENDING`).
    public static let maxPending = 20

    /// The process-wide in-memory store the `Mero` / `SsoLogin` helpers use by default.
    public static let shared = AuthLoginStateStore()

    private let lock = NSLock()
    private let store: AnyValueStore<PendingAuthLogins>
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: where pending logins live. In memory by default.
    ///   - lifetime: how long a begun login stays answerable, in seconds.
    ///   - now: the clock (injectable for tests).
    public init(
        store: AnyValueStore<PendingAuthLogins> = .memory(),
        lifetime: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.lifetime = lifetime
        self.now = now
    }

    #if canImport(Security)
    /// A store kept in one Keychain item, so a login begun before the app was
    /// suspended or relaunched can still be finished.
    public static func keychain(
        account: String = "calimero.auth.login.pending",
        service: String = "network.calimero.merokit",
        accessGroup: String? = nil
    ) -> AuthLoginStateStore {
        AuthLoginStateStore(store: .keychain(account: account, service: service, accessGroup: accessGroup))
    }
    #endif

    /// Remember a new login and return its state: 16 random bytes, hex.
    public func begin() -> String {
        let state = Hex.encode(randomBytes(16))
        lock.lock()
        defer { lock.unlock() }
        let nowMs = now().timeIntervalSince1970 * 1000
        var pending = live(at: nowMs)
        if pending.count >= Self.maxPending {
            // Keep the newest; a page that builds a login URL on every render
            // must not grow this without bound.
            let kept = pending.sorted { $0.value > $1.value }.prefix(Self.maxPending - 1)
            pending = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        pending[state] = nowMs + lifetime * 1000
        store.save(PendingAuthLogins(expiries: pending))
        return state
    }

    /// Consume `state`: `true` only if this store began it, it has not
    /// expired, and it was not taken before.
    public func take(_ state: String?) -> Bool {
        guard let state, !state.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        var pending = live(at: now().timeIntervalSince1970 * 1000)
        guard pending.removeValue(forKey: state) != nil else { return false }
        store.save(PendingAuthLogins(expiries: pending))
        return true
    }

    /// Forget every pending login.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.clear()
    }

    /// The pending logins that have not expired. Caller holds `lock`.
    private func live(at nowMs: Double) -> [String: Double] {
        (store.load()?.expiries ?? [:]).filter { $0.value > nowMs }
    }
}

public enum SsoLogin {
    /// The query parameter the login state rides in, on the callback URL.
    /// (== mero-js `STATE_PARAM`.)
    public static let stateParam = "auth_state"

    /// Parse tokens from the hash fragment of an SSO callback URL.
    /// (== mero-js `parseAuthCallback`; the node emits the same fragment for web and mobile.)
    ///
    /// Returns `nil` if `access_token` is absent, **or if the callback does
    /// not answer a login begun with** ``buildAuthLoginUrl(nodeUrl:options:stateStore:)``
    /// against the same `stateStore` — its `auth_state` must still be pending,
    /// and is consumed (single use). Pass
    /// `ParseAuthCallbackOptions(allowUnsolicited: true)` only for a trusted
    /// host that injects tokens itself.
    public static func parseAuthCallback(
        _ url: String,
        options: ParseAuthCallbackOptions = ParseAuthCallbackOptions(),
        stateStore: AuthLoginStateStore = .shared
    ) -> AuthCallbackResult? {
        guard let hashIndex = url.firstIndex(of: "#") else { return nil }
        let fragment = String(url[url.index(after: hashIndex)...])
        let params = parseQuery(fragment)

        guard let accessToken = params["access_token"], !accessToken.isEmpty else { return nil }

        if !options.allowUnsolicited, !stateStore.take(stateOf(url, hashIndex: hashIndex)) {
            // Tokens for a login this app never began: ignore them.
            return nil
        }

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
    ///
    /// Begins a login in `stateStore` and adds its `auth_state` to the
    /// callback URL's query, so ``parseAuthCallback(_:options:stateStore:)``
    /// can match the callback to it. Query values are form-encoded exactly as
    /// `URLSearchParams` encodes them.
    public static func buildAuthLoginUrl(
        nodeUrl: String,
        options: AuthLoginOptions,
        stateStore: AuthLoginStateStore = .shared
    ) -> String {
        let callback = withState(options.callbackUrl, state: stateStore.begin())

        var items: [(String, String)] = [("callback-url", callback)]

        if let permissions = options.permissions, !permissions.isEmpty {
            items.append(("permissions", permissions.joined(separator: ",")))
        }

        items.append(("mode", options.mode))

        if let packageName = options.packageName, !packageName.isEmpty {
            items.append(("package-name", packageName))
            if let packageVersion = options.packageVersion, !packageVersion.isEmpty {
                items.append(("package-version", packageVersion))
            }
            if let registryUrl = options.registryUrl, !registryUrl.isEmpty {
                items.append(("registry-url", registryUrl))
            }
        }

        // Trim trailing slashes from nodeUrl.
        var base = nodeUrl
        while base.hasSuffix("/") { base.removeLast() }

        let query = items.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return "\(base)/auth/login?\(query)"
    }

    /// `callbackUrl` with `auth_state` set in its query (replacing any one
    /// already there), keeping the rest of the URL as it was.
    static func withState(_ callbackUrl: String, state: String) -> String {
        let pair = "\(stateParam)=\(state)"  // hex: nothing to encode
        if var comps = URLComponents(string: callbackUrl) {
            let kept = (comps.percentEncodedQuery ?? "")
                .split(separator: "&", omittingEmptySubsequences: true)
                .filter { !$0.hasPrefix("\(stateParam)=") && $0 != Substring(stateParam) }
                .map(String.init)
            comps.percentEncodedQuery = (kept + [pair]).joined(separator: "&")
            if let built = comps.string { return built }
        }
        // Not a URL URLComponents can take apart: append, before any fragment.
        var head = callbackUrl
        var tail = ""
        if let hash = callbackUrl.firstIndex(of: "#") {
            head = String(callbackUrl[..<hash])
            tail = String(callbackUrl[hash...])
        }
        return head + (head.contains("?") ? "&" : "?") + pair + tail
    }

    /// The `auth_state` in the query before the fragment, if any.
    private static func stateOf(_ url: String, hashIndex: String.Index) -> String? {
        guard let queryIndex = url.firstIndex(of: "?"), queryIndex < hashIndex else { return nil }
        let query = String(url[url.index(after: queryIndex)..<hashIndex])
        return parseQuery(query)[stateParam]
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

    /// The characters `URLSearchParams` leaves as they are.
    private static let formUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._ ")

    /// Encode as `URLSearchParams.toString()` does: space → `+`, every byte
    /// outside `[A-Za-z0-9*-._]` percent-encoded.
    static func formEncode(_ s: String) -> String {
        let encoded = s.addingPercentEncoding(withAllowedCharacters: formUnreserved) ?? s
        return encoded.replacingOccurrences(of: " ", with: "+")
    }
}
