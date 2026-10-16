import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The delegated half of connecting: an account, a certified device, and the
// relays that write on their behalf. Port of mero-js `src/account/session.ts`
// (the relay map, nonces and pinned keys) and `govern.ts` (the namespace of a
// subgroup).
//
// mero-js keeps this in `localStorage`; here it is a ``DelegatedAccountStore``
// over any ``SecureValueStore`` — `UserDefaults` by default (URLs and ids,
// nothing secret), the Keychain or memory when an app prefers. The device's
// secret is never in it: that stays in the key store ``CloudSignIn`` uses.

/// What a delegated connection needs: an account, its device certificate, the
/// device's keys, and — once there is one — the relay to write through.
/// (== mero-js `DelegatedSession`.)
///
/// `relayUrl == nil` is a signed-in state, not a broken one: a brand-new
/// account is a member of nothing, so no relay serves it until it redeems an
/// invitation (``DelegatedAccounts/joinAsAccount(_:namespaceId:invitation:cloudBaseURL:env:onJoined:)``).
public struct DelegatedSession: Sendable, Equatable {
    /// The author's account id, 64 hex.
    public var account: String
    /// The author's `AccountProof<DeviceCert>`, hex.
    public var credential: String
    /// The certified device's keys; they sign every warrant, request and join.
    public var keys: DeviceKeys
    /// The relay to write through, or `nil` for none yet.
    public var relayUrl: String?
    /// The relay's executor account, when the cloud named it beside the
    /// relay. Founding a namespace needs it, and a namespace that does not
    /// exist yet cannot be asked for it.
    public var executorAccount: String?

    public init(
        account: String, credential: String, keys: DeviceKeys, relayUrl: String? = nil,
        executorAccount: String? = nil
    ) {
        self.account = account.lowercased()
        self.credential = credential
        self.keys = keys
        self.relayUrl = relayUrl.map(DelegatedAccounts.relayOrigin)
        self.executorAccount = executorAccount?.lowercased()
    }

    /// A ``CloudSignIn`` session with this device's keys.
    public init(_ session: CloudSession, keys: DeviceKeys) {
        self.init(
            account: session.account, credential: session.credential, keys: keys, relayUrl: session.relayUrl,
            executorAccount: session.executorAccount)
    }

    /// The same account and device on another relay (no executor carried).
    public func on(relay relayUrl: String?) -> DelegatedSession {
        DelegatedSession(account: account, credential: credential, keys: keys, relayUrl: relayUrl)
    }
}

/// Which relay serves which of an account's namespaces and contexts.
/// (== mero-js `RelayMap`.)
public struct RelayMap: Codable, Sendable, Equatable {
    /// `namespace id → relay URL`, learned when a join or a founding succeeds.
    public var namespaces: [String: String]
    /// `context id → relay URL`, learned from each relay's caller-scoped listing.
    public var contexts: [String: String]

    public init(namespaces: [String: String] = [:], contexts: [String: String] = [:]) {
        self.namespaces = namespaces
        self.contexts = contexts
    }
}

/// Everything a ``DelegatedAccountStore`` persists, per account.
public struct DelegatedAccountState: Codable, Sendable, Equatable {
    /// `account → relay map`.
    public var relayMaps: [String: RelayMap]
    /// `account → (subgroup id → namespace id)`.
    public var groupNamespaces: [String: [String: String]]
    /// `relay URL → its node key`, pinned once learned.
    public var relayNodeKeys: [String: String]

    public init(
        relayMaps: [String: RelayMap] = [:], groupNamespaces: [String: [String: String]] = [:],
        relayNodeKeys: [String: String] = [:]
    ) {
        self.relayMaps = relayMaps
        self.groupNamespaces = groupNamespaces
        self.relayNodeKeys = relayNodeKeys
    }
}

/// A `Codable` value in `UserDefaults`, as JSON under one key.
public final class UserDefaultsValueStore<Value: Codable & Sendable>: SecureValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Value? {
        defaults.data(forKey: key).flatMap { try? MeroJSON.decode(Value.self, from: $0) }
    }

    public func save(_ value: Value) {
        guard let data = try? MeroJSON.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Where an account's relay map, the namespaces of its subgroups and the
/// relays' pinned node keys are kept. Thread-safe.
///
/// What this process learned stands even if the backing store fails: the
/// state is held in memory and written through, so a store that cannot write
/// never turns a known relay back into an unknown one.
public final class DelegatedAccountStore: @unchecked Sendable {
    /// The process-wide store, in `UserDefaults` (`calimero.delegated.state`).
    public static let shared = DelegatedAccountStore.userDefaults()

    private let backing: AnyValueStore<DelegatedAccountState>
    private let lock = NSLock()
    private var state: DelegatedAccountState

    public init(_ backing: AnyValueStore<DelegatedAccountState>) {
        self.backing = backing
        self.state = backing.load() ?? DelegatedAccountState()
    }

    /// A store that keeps nothing past the process (tests, previews).
    public static func memory(_ initial: DelegatedAccountState = DelegatedAccountState()) -> DelegatedAccountStore {
        DelegatedAccountStore(.memory(initial))
    }

    /// A store in `UserDefaults` under `key`.
    public static func userDefaults(
        _ defaults: UserDefaults = .standard, key: String = "calimero.delegated.state"
    ) -> DelegatedAccountStore {
        let store = UserDefaultsValueStore<DelegatedAccountState>(defaults: defaults, key: key)
        return DelegatedAccountStore(AnyValueStore(store))
    }

    #if canImport(Security)
    /// A store in one Keychain item.
    public static func keychain(
        account: String = "delegated-state", service: String = "network.calimero.merokit", accessGroup: String? = nil
    ) -> DelegatedAccountStore {
        DelegatedAccountStore(.keychain(account: account, service: service, accessGroup: accessGroup))
    }
    #endif

    /// Everything held, as it stands.
    public var snapshot: DelegatedAccountState { locked { state } }

    // MARK: - Relay map

    /// The relay map of `account` (empty when nothing is known).
    public func relayMap(account: String) -> RelayMap {
        locked { state.relayMaps[account.lowercased()] ?? RelayMap() }
    }

    /// Replace the relay map of `account`.
    public func setRelayMap(_ map: RelayMap, account: String) {
        update { $0.relayMaps[account.lowercased()] = map }
    }

    /// Record the relay that serves `namespaceId` and/or `contextId` for `account`.
    public func rememberRelay(account: String, relayURL: String, namespaceId: String? = nil, contextId: String? = nil) {
        let url = DelegatedAccounts.relayOrigin(relayURL)
        update { state in
            var map = state.relayMaps[account.lowercased()] ?? RelayMap()
            if let namespaceId { map.namespaces[namespaceId] = url }
            if let contextId { map.contexts[contextId] = url }
            state.relayMaps[account.lowercased()] = map
        }
    }

    // MARK: - Subgroup namespaces

    /// The `subgroup → namespace` records of `account`.
    public func groupNamespaces(account: String) -> [String: String] {
        locked { state.groupNamespaces[account.lowercased()] ?? [:] }
    }

    /// Record that `groupId` is a subgroup of `namespaceId`, for `account`.
    public func rememberGroupNamespace(account: String, groupId: String, namespaceId: String) {
        update { $0.groupNamespaces[account.lowercased(), default: [:]][groupId] = namespaceId }
    }

    // MARK: - Pinned relay node keys

    /// Pin a relay's node signing key (64 hex), learned from its attestation
    /// or out of band — never read from the relay being logged in to.
    public func pinRelayNodeKey(relayURL: String, nodeKey: String) {
        let key = nodeKey.trimmingCharacters(in: .whitespaces).lowercased()
        update { $0.relayNodeKeys[DelegatedAccounts.relayOrigin(relayURL)] = key }
    }

    /// The pinned key for a relay, or `nil` when none (or a malformed one) is pinned.
    public func pinnedRelayNodeKey(relayURL: String) -> String? {
        guard let key = locked({ state.relayNodeKeys[DelegatedAccounts.relayOrigin(relayURL)] }), Hex.is32(key),
            key == key.lowercased()
        else { return nil }
        return key
    }

    /// Forget a relay's pinned key.
    public func forgetRelayNodeKey(relayURL: String) {
        update { $0.relayNodeKeys[DelegatedAccounts.relayOrigin(relayURL)] = nil }
    }

    /// Forget everything.
    public func clear() {
        lock.lock()
        state = DelegatedAccountState()
        lock.unlock()
        backing.clear()
    }

    private func update(_ change: (inout DelegatedAccountState) -> Void) {
        lock.lock()
        change(&state)
        let current = state
        lock.unlock()
        backing.save(current)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Everything the delegated helpers reach the network and storage with.
public struct DelegatedEnvironment: Sendable {
    /// The relay map, subgroup namespaces and pinned node keys.
    public var store: DelegatedAccountStore
    /// Warrant nonces, one sequence per relay (``WarrantNonceStore``).
    public var nonces: any WarrantNonceStore
    public var urlSession: URLSession
    /// Decides whether to trust a relay's attested node key.
    public var relayKeyVerifier: any RelayKeyVerifier
    /// The cloud manager: invitation routing and HA.
    public var cloudBaseURL: URL
    /// What a relay login binds the session to.
    public var audience: LoginAudience
    /// `client_name` on relay logins.
    public var clientName: String?
    /// Warrant lifetime.
    public var warrantTTLSeconds: UInt64
    /// Per-request timeout.
    public var timeout: TimeInterval
    /// How ``DelegatedAccounts/learnRelayNodeKey(_:env:)`` waits between attempts.
    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(
        store: DelegatedAccountStore = .shared, nonces: any WarrantNonceStore = UserDefaultsWarrantNonceStore(),
        urlSession: URLSession = .shared, relayKeyVerifier: any RelayKeyVerifier = TLSRelayKeyVerifier(),
        cloudBaseURL: URL = CloudClient.defaultBaseURL, audience: LoginAudience = .current, clientName: String? = nil,
        warrantTTLSeconds: UInt64 = 300, timeout: TimeInterval = 15,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.store = store
        self.nonces = nonces
        self.urlSession = urlSession
        self.relayKeyVerifier = relayKeyVerifier
        self.cloudBaseURL = cloudBaseURL
        self.audience = audience
        self.clientName = clientName
        self.warrantTTLSeconds = warrantTTLSeconds
        self.timeout = timeout
        self.sleep = sleep
    }

    /// The environment ``CloudSignIn`` runs with.
    public init(
        _ config: CloudConfig, store: DelegatedAccountStore = .shared,
        nonces: any WarrantNonceStore = UserDefaultsWarrantNonceStore(), urlSession: URLSession = .shared
    ) {
        self.init(
            store: store, nonces: nonces, urlSession: urlSession, relayKeyVerifier: config.relayKeyVerifier,
            cloudBaseURL: config.cloudBaseURL, audience: config.audience, clientName: config.clientName,
            warrantTTLSeconds: config.warrantTTLSeconds)
    }
}

/// The delegated-account layer: relay map, relay keys, delegated clients,
/// governance and joins. (== mero-js `src/account/session.ts`, `govern.ts`,
/// `create-context.ts`, `join-as-account.ts`.)
public enum DelegatedAccounts {
    /// A relay URL with trailing slashes trimmed, so a pasted URL and a typed
    /// one address one relay.
    static func relayOrigin(_ relayURL: String) -> String {
        var trimmed = relayURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: - Relay map

    /// The relay map of `account`. (== mero-js `readRelayMap`.)
    public static func readRelayMap(_ account: String, store: DelegatedAccountStore = .shared) -> RelayMap {
        store.relayMap(account: account)
    }

    /// Record the relay that admitted `account` to a namespace (and, when
    /// known, the context it came for). (== mero-js `rememberRelay`.)
    public static func rememberRelay(
        _ account: String, relayURL: String, namespaceId: String? = nil, contextId: String? = nil,
        store: DelegatedAccountStore = .shared
    ) {
        store.rememberRelay(account: account, relayURL: relayURL, namespaceId: namespaceId, contextId: contextId)
    }

    /// The relay that serves `contextId`, if `account` has learned it.
    public static func relayForContext(
        _ account: String, contextId: String, store: DelegatedAccountStore = .shared
    ) -> String? {
        store.relayMap(account: account).contexts[contextId]
    }

    /// A session moving to `next`, keeping the relay's executor account the
    /// previous one knew when both are on the same relay. On a different
    /// relay the old executor is the wrong account, so it is left behind.
    /// (== mero-js `carryExecutorAccount`.)
    public static func carryExecutorAccount(
        from previous: DelegatedSession?, to next: DelegatedSession
    ) -> DelegatedSession {
        guard next.executorAccount == nil, let previous, let executor = previous.executorAccount,
            let before = previous.relayUrl, let after = next.relayUrl, relayOrigin(before) == relayOrigin(after)
        else { return next }
        var carried = next
        carried.executorAccount = executor
        return carried
    }

    /// Every relay this account is known to use: the session's first, then
    /// each in the map, once each.
    public static func knownRelays(_ session: DelegatedSession, store: DelegatedAccountStore = .shared) -> [String] {
        let map = store.relayMap(account: session.account)
        let first = [session.relayUrl].compactMap { $0 }
        let byNamespace = map.namespaces.keys.sorted().compactMap { map.namespaces[$0] }
        let byContext = map.contexts.keys.sorted().compactMap { map.contexts[$0] }
        let all = first + byNamespace + byContext
        var seen = Set<String>()
        return all.filter { !$0.isEmpty }.map(relayOrigin).filter { seen.insert($0).inserted }
    }

    // MARK: - Subgroup namespaces

    /// Record that `groupId` is a subgroup of `namespaceId`, for `account`.
    public static func rememberGroupNamespace(
        _ account: String, groupId: String, namespaceId: String, store: DelegatedAccountStore = .shared
    ) {
        store.rememberGroupNamespace(account: account, groupId: groupId, namespaceId: namespaceId)
    }

    /// The namespace `groupId` belongs to: itself when it is a namespace this
    /// account is in, else what was remembered, else `nil`.
    public static func namespaceOfGroup(
        _ session: DelegatedSession, groupId: String, store: DelegatedAccountStore = .shared
    ) -> String? {
        if store.relayMap(account: session.account).namespaces[groupId] != nil { return groupId }
        return store.groupNamespaces(account: session.account)[groupId]
    }

    // MARK: - Nonces

    /// Record that `nonce` is spent for this device on `relayURL`, so later
    /// warrants start above it. One sequence per relay covers a new context's
    /// window like any other. (== mero-js `markContextNonceSpent`.)
    public static func markContextNonceSpent(
        relayURL: String, contextId: String, nonce: UInt64, nonces: any WarrantNonceStore
    ) {
        _ = contextId
        nonces.advance(relay: relayOrigin(relayURL), to: nonce &+ 1)
    }
}
