import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Linking an account to a cloud login from an app that holds the account
// root and no cloud session. Port of mero-js `src/cloud/link-redirect.ts`,
// `link-state.ts` and `CloudClient.accountLinkHandoff` /
// `readAccountLinkCallback`.
//
// The link needs a cloud session, which only Google mints, and a root
// signature, which only the holder can make. So the person goes to the cloud,
// where they are signed in, and consents to linking one named account; the
// cloud redirects back with a **grant** in the URL fragment — that login's
// sealed consent, spendable only by whoever signs with the account's root.
// Show the person the account id before sending them: the consent screen is
// the only check that they meant this account.
//
// mero-js redirects the page (`window.location`) and remembers each begun link
// in `localStorage`. Natively the consent page opens in the system auth sheet
// (MeroKitUI's `CloudLink.beginCloudLink(accountId:callback:...)`), and begun
// links live in a ``CloudLinkStateStore``.

/// One link this app began: the account it was for, and when it lapses.
public struct PendingCloudLink: Codable, Sendable, Equatable {
    public var account: String
    /// Epoch milliseconds.
    public var expiresAtMs: Double

    public init(account: String, expiresAtMs: Double) {
        self.account = account
        self.expiresAtMs = expiresAtMs
    }
}

/// Every link this app began and has not yet seen answered.
public struct PendingCloudLinks: Codable, Sendable, Equatable {
    public var entries: [String: PendingCloudLink]

    public init(entries: [String: PendingCloudLink] = [:]) {
        self.entries = entries
    }
}

/// Links this app began, so a callback can be matched to one — single use,
/// for the account it named, within ``defaultLifetime``. (== the
/// `calimero.cloud.link.pending` store of mero-js `link-state.ts`.)
///
/// The callback URL can be forwarded, so a grant is only accepted when it
/// answers a link begun here. ``shared`` is in memory: a link begun and
/// finished in one launch. Use ``keychain(account:service:accessGroup:)`` when
/// the callback can arrive after a relaunch.
public final class CloudLinkStateStore: @unchecked Sendable {
    /// A grant lives 5 minutes, plus time to consent: 10 minutes.
    public static let defaultLifetime: TimeInterval = 10 * 60
    /// Links kept at once; the oldest are dropped.
    public static let maxPending = 20

    /// The process-wide in-memory store the link helpers use by default.
    public static let shared = CloudLinkStateStore()

    private let lock = NSLock()
    private let store: AnyValueStore<PendingCloudLinks>
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: AnyValueStore<PendingCloudLinks> = .memory(),
        lifetime: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.lifetime = lifetime
        self.now = now
    }

    #if canImport(Security)
    /// A store kept in one Keychain item.
    public static func keychain(
        account: String = "calimero.cloud.link.pending",
        service: String = "network.calimero.merokit",
        accessGroup: String? = nil
    ) -> CloudLinkStateStore {
        CloudLinkStateStore(store: .keychain(account: account, service: service, accessGroup: accessGroup))
    }
    #endif

    /// Remember a link for `account` and return its state: 16 random bytes, hex.
    public func begin(account: String) -> String {
        let state = Hex.encode(randomBytes(16))
        lock.lock()
        defer { lock.unlock() }
        let nowMs = now().timeIntervalSince1970 * 1000
        var pending = live(at: nowMs)
        if pending.count >= Self.maxPending {
            let kept = pending.sorted { $0.value.expiresAtMs > $1.value.expiresAtMs }.prefix(Self.maxPending - 1)
            pending = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        pending[state] = PendingCloudLink(account: account, expiresAtMs: nowMs + lifetime * 1000)
        store.save(PendingCloudLinks(entries: pending))
        return state
    }

    /// Remove and return what `state` was begun with, or `nil` when this app
    /// did not begin it, it lapsed, or it was taken before.
    public func take(_ state: String?) -> PendingCloudLink? {
        guard let state, !state.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var pending = live(at: now().timeIntervalSince1970 * 1000)
        guard let entry = pending.removeValue(forKey: state) else { return nil }
        store.save(PendingCloudLinks(entries: pending))
        return entry
    }

    /// The links still pending (not lapsed).
    public func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return live(at: now().timeIntervalSince1970 * 1000).count
    }

    /// Forget every pending link.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.clear()
    }

    /// Caller holds `lock`.
    private func live(at nowMs: Double) -> [String: PendingCloudLink] {
        (store.load()?.entries ?? [:]).filter { $0.value.expiresAtMs > nowMs }
    }
}

/// A grant the cloud handed back. (== mero-js `CloudLinkCallback`.)
public struct CloudLinkCallback: Sendable, Equatable {
    public let grant: String
    /// The account the cloud sealed into the grant.
    public let account: String

    public init(grant: String, account: String) {
        self.grant = grant
        self.account = account
    }
}

/// The redirect half of linking an account to a cloud login.
public enum CloudLink {
    /// Where the consent screen lives: the web app, not the manager API.
    public static let defaultCloudWebURL = URL(string: "https://cloud.calimero.network")!
    /// The query parameter a link's state rides in on the return URL.
    public static let stateParam = "link_state"

    /// The consent URL to open: `?link-account=<id>&callback-url=<returnTo
    /// carrying link_state>`. Remembers the link in `stateStore` so
    /// ``readCloudLinkCallback(_:stateStore:)`` can match the answer.
    /// (== mero-js `cloudLinkUrl`.)
    ///
    /// - Parameters:
    ///   - accountId: 64 lowercase hex — derive it, show it, never let a person type it.
    ///   - returnTo: where the cloud sends the person back (an https URL or an
    ///     app scheme the auth sheet listens for). The grant comes back in its
    ///     fragment.
    public static func cloudLinkUrl(
        accountId: String, returnTo: String, cloudWebURL: URL = defaultCloudWebURL,
        stateStore: CloudLinkStateStore = .shared
    ) throws -> URL {
        let callback = try beginLinkState(account: accountId, returnTo: returnTo, stateStore: stateStore)
        guard var components = URLComponents(url: cloudWebURL, resolvingAgainstBaseURL: false) else {
            throw AccountError.invalidInput("cloudWebURL is not a URL: \(cloudWebURL)")
        }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        let ours: Set<String> = ["link-account", "callback-url"]
        let kept = (components.percentEncodedQuery ?? "").split(separator: "&").map(String.init).filter { pair in
            guard let name = DeviceEnrolment.formDecodeQuery(pair).keys.first else { return true }
            return !ours.contains(name)
        }
        let added = [("link-account", accountId), ("callback-url", callback)].map {
            "\(DeviceEnrolment.formEncode($0.0))=\(DeviceEnrolment.formEncode($0.1))"
        }
        components.percentEncodedQuery = (kept + added).joined(separator: "&")
        guard let url = components.url else { throw AccountError.invalidInput("could not build the link URL") }
        return url
    }

    /// Read a grant out of a callback URL's fragment.
    ///
    /// `nil` on a URL that carries none, so it can be run on every incoming
    /// URL. Throws ``AccountError/linkDeclined(_:)`` when the person declined
    /// (forgetting the pending link), and ``AccountError/stateMismatch`` when
    /// the grant does not answer a link this app began **for that account** —
    /// the state is spent either way, so a callback is accepted at most once.
    /// (== mero-js `readCloudLinkCallback`.)
    public static func readCloudLinkCallback(
        _ url: URL, stateStore: CloudLinkStateStore = .shared
    ) throws -> CloudLinkCallback? {
        let params = DeviceEnrolment.formDecodeQuery(url.fragment ?? "")
        let state = linkState(query: url.query)
        if let error = params["error"], !error.isEmpty {
            _ = stateStore.take(state)
            throw AccountError.linkDeclined(
                error == "denied"
                    ? "the account link was declined at the cloud"
                    : "the cloud refused this link: \(error)")
        }
        guard let grant = params["grant"], !grant.isEmpty, let account = params["account"], !account.isEmpty else {
            return nil
        }
        guard stateStore.take(state)?.account == account else { throw AccountError.stateMismatch }
        return CloudLinkCallback(grant: grant, account: account)
    }

    /// Spend the grant: sign it with the root and hand it to the cloud,
    /// anonymously (``CloudClient/linkAccountWithGrant(grant:rootSecret:signer:)``).
    /// Refuses, before sending anything, a grant for another account than the
    /// root derives. (== mero-js `completeCloudLink`.)
    @discardableResult
    public static func completeCloudLink(
        _ callback: CloudLinkCallback, root: RootSource, cloudBaseURL: URL = CloudClient.defaultBaseURL,
        session: URLSession = .shared
    ) async throws -> CloudAccountLink {
        let resolved = try resolveRoot(root)
        guard resolved.accountId == callback.account else {
            throw AccountError.invalidInput(
                "this grant is for account \(callback.account), but the root here derives \(resolved.accountId) — "
                    + "it was minted for a different account")
        }
        return try await CloudClient(baseURL: cloudBaseURL, session: session)
            .linkAccountWithGrant(grant: callback.grant, signer: resolved.signer)
    }

    /// `url` without its fragment and `link_state` — what to keep once a
    /// callback is read, so it is not replayed. (== mero-js `withoutLinkState`.)
    public static func strippingCallback(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        let kept = (components.percentEncodedQuery ?? "").split(separator: "&").filter {
            !$0.hasPrefix("\(stateParam)=") && $0 != Substring(stateParam)
        }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url ?? url
    }

    // MARK: - State

    /// Remember a link for `account` and return `returnTo` carrying its state
    /// (replacing any `link_state` already there). Validates both first, so a
    /// bad return URL begins nothing. (== mero-js `beginLinkState`.)
    static func beginLinkState(account: String, returnTo: String, stateStore: CloudLinkStateStore) throws -> String {
        guard account.count == 64, account == account.lowercased(), Hex.is32(account) else {
            throw AccountError.invalidInput("accountId must be 64 lowercase hex characters")
        }
        guard var parsed = URLComponents(string: returnTo), parsed.scheme != nil, parsed.fragment == nil else {
            throw AccountError.invalidInput("returnTo must be an absolute URL without a fragment, got \(returnTo)")
        }
        let state = stateStore.begin(account: account)
        let kept = (parsed.percentEncodedQuery ?? "").split(separator: "&").map(String.init).filter {
            !$0.hasPrefix("\(stateParam)=") && $0 != stateParam
        }
        parsed.percentEncodedQuery = (kept + ["\(stateParam)=\(state)"]).joined(separator: "&")
        guard let built = parsed.string else {
            _ = stateStore.take(state)
            throw AccountError.invalidInput("could not add the link state to \(returnTo)")
        }
        return built
    }

    /// The `link_state` in a (percent-encoded) query.
    static func linkState(query: String?) -> String? {
        DeviceEnrolment.formDecodeQuery(query ?? "")[stateParam]
    }
}

// MARK: - The portal handoff

extension CloudClient {
    /// Where to send someone to authorise linking `accountId`: the portal's
    /// `/?link-account=…&callback-url=…`, the callback carrying a fresh
    /// `link_state`. Static: there is nothing to authenticate as yet. Pairs
    /// with ``readAccountLinkCallback(_:stateStore:)`` and
    /// ``linkAccountWithGrant(grant:rootSecret:signer:)``.
    public static func accountLinkHandoff(
        portalURL: String, accountId: String, callbackURL: String, stateStore: CloudLinkStateStore = .shared
    ) throws -> AccountLinkHandoff {
        var portal = portalURL
        while portal.hasSuffix("/") { portal.removeLast() }
        let callback = try CloudLink.beginLinkState(account: accountId, returnTo: callbackURL, stateStore: stateStore)
        let query = [("link-account", accountId), ("callback-url", callback)]
            .map { "\(DeviceEnrolment.formEncode($0.0))=\(DeviceEnrolment.formEncode($0.1))" }
            .joined(separator: "&")
        guard let url = URL(string: "\(portal)/?\(query)") else {
            throw AccountError.invalidInput("portalURL is not a URL: \(portalURL)")
        }
        return AccountLinkHandoff(url: url, accountId: accountId)
    }

    /// Read the portal's answer out of a callback URL's **fragment** (a grant
    /// in the query is ignored). Every field `nil` when there is nothing to
    /// read. A grant that does not answer a handoff this app began, for the
    /// account it named, comes back as `error: "unexpected_callback"`.
    public static func readAccountLinkCallback(
        _ href: String, stateStore: CloudLinkStateStore = .shared
    ) -> AccountLinkCallback {
        guard let url = URL(string: href), url.scheme != nil else { return AccountLinkCallback() }
        let params = DeviceEnrolment.formDecodeQuery(url.fragment ?? "")
        let state = CloudLink.linkState(query: url.query)
        let grant = params["grant"].flatMap { $0.isEmpty ? nil : $0 }
        let accountId = params["account"].flatMap { $0.isEmpty ? nil : $0 }
        let error = params["error"].flatMap { $0.isEmpty ? nil : $0 }
        if error != nil { _ = stateStore.take(state) }
        if grant != nil, stateStore.take(state)?.account != accountId {
            return AccountLinkCallback(error: "unexpected_callback")
        }
        return AccountLinkCallback(grant: grant, accountId: accountId, error: error)
    }
}

// MARK: - Foreign callbacks

/// Is the answer going somewhere other than the page that asked? Compares
/// web origins (scheme, host, non-default port); `false` when either side is
/// unknown or `returnTo` is not a URL. A smell, not a verdict — a sibling
/// callback host is legitimate — so a wallet can show it to the person
/// approving. A custom app scheme has an opaque (`null`) origin, as in a
/// browser. (== mero-js `callbackIsForeign`.)
public func callbackIsForeign(_ returnTo: String, pageOrigin: String?) -> Bool {
    guard let pageOrigin, !pageOrigin.isEmpty, let there = webOrigin(returnTo) else { return false }
    return there != (webOrigin(pageOrigin) ?? pageOrigin)
}

/// `URL.origin` as a browser serialises it, or `nil` when `value` is not an
/// absolute URL.
func webOrigin(_ value: String) -> String? {
    guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
        return nil
    }
    let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]
    guard let defaultPort = defaultPorts[scheme] else { return "null" }
    guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
    let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    guard let port = components.port, port != defaultPort else { return "\(scheme)://\(shownHost)" }
    return "\(scheme)://\(shownHost):\(port)"
}
