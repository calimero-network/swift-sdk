import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The login session a ``CloudClient`` and its copies share.
///
/// Every method is synchronous so the lock is never held across a suspension.
/// Persistence and the callback run after the lock is released, so a slow or
/// failing store cannot stall a request.
final class CloudLoginState: @unchecked Sendable {
    /// Response headers MDMA hands a rolling-refreshed session back in.
    static let refreshHeader = "x-mdma-session-refresh"
    static let refreshExpiresHeader = "x-mdma-session-expires"

    private let lock = NSLock()
    private var current: CloudLoginSession?
    private let store: AnyValueStore<CloudLoginSession>?
    private let onSession: (@Sendable (CloudLoginSession?) -> Void)?

    init(
        initial: CloudLoginSession?, store: AnyValueStore<CloudLoginSession>?,
        onSession: (@Sendable (CloudLoginSession?) -> Void)?
    ) {
        self.current = initial
        self.store = store
        self.onSession = onSession
    }

    func get() -> CloudLoginSession? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Replace the session (or forget it) and tell the store and the app.
    func set(_ session: CloudLoginSession?) {
        lock.lock()
        current = session
        lock.unlock()
        if let session { store?.save(session) } else { store?.clear() }
        onSession?(session)
    }

    /// Adopt a token the server rotated mid-request. The user carries over:
    /// the header holds only a token, and the refresh is the same login.
    func adoptRollingRefresh(_ headers: [String: String]) {
        guard let token = headers[Self.refreshHeader], !token.isEmpty, let previous = get() else { return }
        let expires = headers[Self.refreshExpiresHeader].flatMap { Double($0) } ?? 0
        let expiresAt = expires.isFinite && expires > 0 ? Int64(expires) : previous.expiresAt
        set(CloudLoginSession(sessionToken: token, expiresAt: expiresAt, user: previous.user))
    }
}

// MARK: - Sign-in

extension CloudClient {
    #if canImport(Security)
    /// A Keychain item for the login session, to pass as `sessionStore`.
    public static func keychainSessionStore(
        account: String = "cloud-login-session", service: String = "network.calimero.merokit",
        accessGroup: String? = nil
    ) -> AnyValueStore<CloudLoginSession> {
        .keychain(account: account, service: service, accessGroup: accessGroup)
    }
    #endif

    /// The current login session, or `nil` when nobody is signed in.
    public func getSession() -> CloudLoginSession? { loginState.get() }

    /// Whether a session token is held. Says nothing about the server agreeing.
    public var isSignedIn: Bool { loginState.get() != nil }

    /// Exchange a Google OAuth2 ID token for an MDMA session
    /// (`POST /api/auth/google`, anonymous). The app owns the Google flow.
    @discardableResult
    public func signInWithGoogle(_ idToken: String) async throws -> CloudLoginSession {
        let body = try await request("POST", "/api/auth/google", body: ["id_token": .string(idToken)], anonymous: true)
        return try adoptSession(body)
    }

    /// Sign in as a Calimero account, proving it with its root: fetch a
    /// challenge, sign it (``signAccountLogin(_:)``), post the proof. Only a
    /// signature over the cloud's nonce travels.
    ///
    /// A `403` means the signature did not verify **or** the account is not
    /// linked to a cloud login; the ownership claim is recorded either way.
    @discardableResult
    public func signInWithAccount(_ root: RootSource) async throws -> CloudLoginSession {
        let resolved = try resolveRoot(root)
        let challenge = try await getAccountLoginChallenge()
        let signature = try await signAccountLogin(AccountLoginInput(signer: resolved.signer, nonce: challenge.nonce))
        return try await submitAccountLogin(
            AccountLoginProof(rootPublicKey: resolved.publicKey, nonce: challenge.nonce, signature: signature))
    }

    /// `GET /api/auth/account/challenge` — public: obtaining a session is what
    /// the exchange does. For a root that signs elsewhere.
    public func getAccountLoginChallenge() async throws -> AccountLoginChallenge {
        let body = try await request("GET", "/api/auth/account/challenge", anonymous: true)
        return AccountLoginChallenge(
            nonce: body["nonce"]?.stringValue ?? "", expiresAtMs: Int64(body["expires_at_ms"]?.doubleValue ?? 0))
    }

    /// `POST /api/auth/account` with a proof assembled elsewhere.
    @discardableResult
    public func submitAccountLogin(_ proof: AccountLoginProof) async throws -> CloudLoginSession {
        let body = try await request(
            "POST", "/api/auth/account",
            body: [
                "root_public_key": .string(proof.rootPublicKey), "nonce": .string(proof.nonce),
                "signature": .string(proof.signature),
            ],
            anonymous: true)
        return try adoptSession(body)
    }

    /// `POST /api/auth/refresh`. Rarely needed: rolling refreshes are adopted
    /// on ordinary calls.
    @discardableResult
    public func refreshSession() async throws -> CloudLoginSession {
        try adoptSession(try await request("POST", "/api/auth/refresh"))
    }

    /// Revoke the session server-side (`POST /api/auth/logout`) and forget it.
    /// Forgotten locally even when the server call fails — which then throws.
    public func signOut() async throws {
        defer { loginState.set(nil) }
        if isSignedIn { _ = try await request("POST", "/api/auth/logout", parse: false) }
    }

    private func adoptSession(_ body: JSONValue) throws -> CloudLoginSession {
        guard let token = body["session_token"]?.stringValue, !token.isEmpty else {
            throw AccountError.protocolViolation("the cloud answered a sign-in without a session_token")
        }
        let user = body["user"]
        let session = CloudLoginSession(
            sessionToken: token, expiresAt: Int64(body["expires_at"]?.doubleValue ?? 0),
            user: CloudUser(
                email: user?["email"]?.stringValue ?? "", name: user?["name"]?.stringValue,
                picture: user?["picture"]?.stringValue))
        loginState.set(session)
        return session
    }
}

// MARK: - Namespaces, relays, machines

extension CloudClient {
    /// The first relay a warrant can be spent at: `canExecute`, with a URL and
    /// an executor account. (== mero-js `pickExecutingRelay`.)
    public static func pickExecutingRelay(_ relays: [CloudRelay]) -> CloudRelay? {
        relays.first { $0.canExecute && $0.relayUrl != nil && $0.executorAccount != nil }
    }

    /// `GET /api/cloud/me/namespaces` — the namespaces the signed-in user owns.
    public func getMyNamespaces() async throws -> [CloudNamespace] {
        let rows = try await request("GET", "/api/cloud/me/namespaces").arrayValue ?? []
        return rows.map { row in
            let namespaceId = row["namespace_id"]?.stringValue ?? row["group_id"]?.stringValue ?? ""
            return CloudNamespace(
                namespaceId: namespaceId,
                groupId: row["group_id"]?.stringValue ?? namespaceId,
                haStatus: row["ha_status"]?.stringValue ?? "none",
                haEnabledAt: row["ha_enabled_at"]?.stringValue,
                contexts: (row["contexts"]?.arrayValue ?? []).compactMap(\.stringValue),
                fleetReplicas: row["fleet_replicas"])
        }
    }

    /// `GET /api/cloud/me/namespaces/{ns}/relays` — where to present an
    /// intent for one owned namespace, and as whom. Filter on `canExecute`.
    public func getNamespaceRelays(_ namespaceId: String) async throws -> [CloudRelay] {
        let body = try await request("GET", "/api/cloud/me/namespaces/\(escape(namespaceId))/relays")
        return (body["relays"]?.arrayValue ?? []).map { row in
            let relayUrl = row["relay_url"]?.stringValue
            let executorAccount = row["executor_account"]?.stringValue
            let authorshipReady = row["authorship_ready"]?.boolValue == true
            return CloudRelay(
                peerId: row["peer_id"]?.stringValue ?? "",
                relayUrl: relayUrl,
                executorAccount: executorAccount,
                nodeKey: row["node_key"]?.stringValue ?? row["node_public_key"]?.stringValue,
                status: row["status"]?.stringValue ?? "",
                authorshipReady: authorshipReady,
                teeRole: Self.teeRole(row),
                canExecute: row["can_execute"]?.boolValue
                    ?? (authorshipReady && relayUrl != nil && executorAccount != nil),
                lastSeenAt: row["last_seen_at"]?.stringValue,
                confirmedAt: row["confirmed_at"]?.stringValue,
                admission: row["admission"]?.stringValue,
                admissionHint: row["admission_hint"]?.stringValue,
                join: Self.join(row["join"]))
        }
    }

    /// The first relay for `namespaceId` that can run an intent now, or `nil`.
    public func findExecutingRelay(_ namespaceId: String) async throws -> CloudRelay? {
        Self.pickExecutingRelay(try await getNamespaceRelays(namespaceId))
    }

    /// `GET /api/cloud/me/machines` — every attested machine serving something
    /// this account owns, with only the caller's namespaces on each.
    ///
    /// mero-js's deprecated `getMyNode` (`/api/cloud/me/node`, a ledger nothing
    /// writes any more) is not ported: this replaces it.
    public func getMyMachines() async throws -> [CloudMachine] {
        let body = try await request("GET", "/api/cloud/me/machines")
        return (body["machines"]?.arrayValue ?? []).map { row in
            let relayUrl = row["relay_url"]?.stringValue
            let executorAccount = row["executor_account"]?.stringValue
            let namespaces = (row["namespaces"]?.arrayValue ?? []).map { ns in
                CloudMachineNamespace(
                    namespaceId: ns["namespace_id"]?.stringValue ?? "",
                    status: ns["status"]?.stringValue ?? "",
                    authorshipReady: ns["authorship_ready"]?.boolValue == true,
                    teeRole: Self.teeRole(ns),
                    fresh: ns["fresh"]?.boolValue == true,
                    confirmedAt: ns["confirmed_at"]?.stringValue,
                    lastSeenAt: ns["last_seen_at"]?.stringValue)
            }
            let legacy = relayUrl != nil && executorAccount != nil && namespaces.contains(where: \.authorshipReady)
            return CloudMachine(
                peerId: row["peer_id"]?.stringValue ?? "",
                relayUrl: relayUrl,
                executorAccount: executorAccount,
                canExecute: row["can_execute"]?.boolValue ?? legacy,
                namespaces: namespaces)
        }
    }

    /// `tee_role`, or `nil` when absent or empty.
    static func teeRole(_ row: JSONValue) -> String? {
        row["tee_role"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A relay's `join` report, or `nil` when absent or malformed.
    static func join(_ raw: JSONValue?) -> CloudRelayJoin? {
        guard let raw, raw.objectValue != nil, let state = raw["state"]?.stringValue else { return nil }
        let refusals = (raw["refusals"]?.arrayValue ?? []).compactMap { entry -> CloudRelayRefusal? in
            guard entry.objectValue != nil else { return nil }
            return CloudRelayRefusal(
                peer: Self.text(entry["peer"]), reason: Self.text(entry["reason"]))
        }
        return CloudRelayJoin(
            state: state, attempts: raw["attempts"]?.intValue ?? 0, refusals: refusals,
            error: raw["error"]?.stringValue, reportedAt: raw["reported_at"]?.stringValue)
    }

    /// `String(value ?? '')`, as mero-js reads a free-text field.
    private static func text(_ value: JSONValue?) -> String {
        switch value ?? .null {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return String(b)
        default: return ""
        }
    }
}

// MARK: - HA

extension CloudClient {
    /// Claim a namespace under this login, proving ownership
    /// (`POST /api/cloud/namespaces/claim`). Pass the node's
    /// ``AdminApi/issueNamespaceOwnershipProof(_:request:)`` answer verbatim:
    /// the cloud accepts core's camelCase, and its `founding`/`credential` ride
    /// along. Idempotent for the same account; `409` if someone else holds it.
    public func claimNamespace(_ namespaceId: String, ownershipProof: JSONValue) async throws {
        _ = try await request(
            "POST", "/api/cloud/namespaces/claim",
            body: ["namespace_id": .string(namespaceId), "ownership_proof": ownershipProof])
    }

    /// ``claimNamespace(_:ownershipProof:)`` with a typed proof, encoded as is.
    public func claimNamespace<Proof: Encodable>(_ namespaceId: String, proof: Proof) async throws {
        let json = try MeroJSON.decode(JSONValue.self, from: try MeroJSON.encode(proof))
        try await claimNamespace(namespaceId, ownershipProof: json)
    }

    /// Ask the fleet to host a claimed namespace
    /// (`POST /api/cloud/namespaces/{ns}/enable-ha`). `admitterAddrs` — from
    /// ``admitterAddrsFromNetworkStatus(_:)`` — is where the owner's node can
    /// be dialled; `nil` leaves what the cloud holds (an empty body, not an
    /// empty list, which would clear it). Not the web page: see ``enableHAURL(_:)``.
    @discardableResult
    public func enableNamespaceHa(_ namespaceId: String, admitterAddrs: [String]? = nil) async throws -> JSONValue {
        var body: JSONValue = [:]
        if let admitterAddrs { body = ["admitter_addrs": .array(admitterAddrs.map { JSONValue.string($0) })] }
        return try await request("POST", "/api/cloud/namespaces/\(escape(namespaceId))/enable-ha", body: body)
    }

    /// Enable HA for a namespace this account founded through a relay, with
    /// the founder's claim (``signAccountOwnershipClaim(_:)``, bound to this
    /// login's email) instead of a node's proof
    /// (`POST /api/cloud/me/namespaces/{ns}/enable-ha`).
    @discardableResult
    public func enableFoundedNamespaceHa(
        _ namespaceId: String, ownershipProof: AccountOwnershipProof
    ) async throws -> JSONValue {
        try await request(
            "POST", "/api/cloud/me/namespaces/\(escape(namespaceId))/enable-ha",
            body: ["groups": .array([]), "ownership_proof": ownershipProof.json])
    }

    /// Stop hosting a claimed namespace (`POST /api/cloud/namespaces/{ns}/disable-ha`).
    /// Each assigned fleet node then self-leaves, and core purges its copy.
    @discardableResult
    public func disableNamespaceHa(_ namespaceId: String) async throws -> JSONValue {
        try await request("POST", "/api/cloud/namespaces/\(escape(namespaceId))/disable-ha", body: [:])
    }

    /// The cloud's `/enable-ha` page, for a person to complete by hand
    /// (`group_id`, `context_id`, `redirect_url`). mero-js opens it with
    /// `window.open`; open it in the system auth sheet — MeroKitUI's
    /// `CloudClient.enableHA(_:callback:authenticator:)` does.
    public func enableHAURL(_ options: HAPageOptions) throws -> URL {
        try haPageURL("/enable-ha", options)
    }

    /// The cloud's `/disable-ha` page. See ``enableHAURL(_:)``.
    public func disableHAURL(_ options: HAPageOptions) throws -> URL {
        try haPageURL("/disable-ha", options)
    }

    private func haPageURL(_ path: String, _ options: HAPageOptions) throws -> URL {
        var items = [("group_id", options.groupId), ("context_id", options.contextId)]
        if let redirect = options.redirectUrl, !redirect.isEmpty { items.append(("redirect_url", redirect)) }
        let query = items.map { "\(SsoLogin.formEncode($0.0))=\(SsoLogin.formEncode($0.1))" }.joined(separator: "&")
        return try AccountHTTP.url(baseURL.absoluteString, "\(path)?\(query)")
    }
}

// MARK: - Account linking

extension CloudClient {
    /// Link a Calimero account to this login, proving its root: fetch a
    /// single-use challenge, sign it (``signAccountLink(_:)``), post the proof.
    /// Idempotent for the same login; `409` linked elsewhere, `403` a replayed
    /// challenge, `402` over the plan's account limit.
    @discardableResult
    public func linkAccount(_ root: RootSource) async throws -> CloudAccountLink {
        let resolved = try resolveRoot(root)
        let challenge = try await getAccountLinkChallenge()
        let signature = try await signAccountLink(AccountLinkInput(signer: resolved.signer, nonce: challenge.nonce))
        return try await submitAccountLink(
            AccountLinkProof(
                accountId: resolved.accountId, rootPublicKey: resolved.publicKey, nonce: challenge.nonce,
                signature: signature))
    }

    /// `GET /api/cloud/me/accounts/challenge` — for a root that signs
    /// elsewhere. Single-use: one fetched and abandoned is spent.
    public func getAccountLinkChallenge() async throws -> AccountLinkChallenge {
        let body = try await request("GET", "/api/cloud/me/accounts/challenge")
        return AccountLinkChallenge(
            nonce: body["nonce"]?.stringValue ?? "", expiresAtMs: body["expires_at_ms"]?.doubleValue.map { Int64($0) })
    }

    /// `POST /api/cloud/me/accounts` with a proof assembled elsewhere.
    /// `accountId` must be the account `rootPublicKey` names.
    @discardableResult
    public func submitAccountLink(_ proof: AccountLinkProof) async throws -> CloudAccountLink {
        let body = try await request(
            "POST", "/api/cloud/me/accounts",
            body: [
                "account_id": .string(proof.accountId), "root_public_key": .string(proof.rootPublicKey),
                "nonce": .string(proof.nonce), "signature": .string(proof.signature),
            ])
        return Self.accountLink(body, fallback: proof.accountId)
    }

    /// Spend a link grant from the portal (``readAccountLinkCallback(_:stateStore:)``):
    /// sign it with the account root as an account-link nonce and post both
    /// halves to `POST /api/cloud/accounts/link`. **Anonymous** even when a
    /// session is held: the grant carries the consenting login. Exactly one of
    /// `rootSecret` and `signer`.
    @discardableResult
    public func linkAccountWithGrant(
        grant: String, rootSecret: String? = nil, signer: (any Signer)? = nil
    ) async throws -> CloudAccountLink {
        let root = try resolveRootPair(rootSecret: rootSecret, signer: signer)
        let signature = try await signAccountLink(AccountLinkInput(signer: root.signer, nonce: grant))
        let body = try await request(
            "POST", "/api/cloud/accounts/link",
            body: [
                "grant": .string(grant), "root_public_key": .string(root.publicKey), "signature": .string(signature),
            ],
            anonymous: true)
        return Self.accountLink(body, fallback: root.accountId)
    }

    /// `GET /api/cloud/me/accounts` — linked accounts and the plan's limit.
    public func getMyAccounts() async throws -> CloudLinkedAccounts {
        let body = try await request("GET", "/api/cloud/me/accounts")
        let accounts = (body["accounts"]?.arrayValue ?? []).map { row in
            CloudLinkedAccount(
                accountId: row["account_id"]?.stringValue ?? "", linkedAt: row["linked_at"]?.stringValue,
                hasRecoveryEnvelope: row["has_recovery_envelope"]?.boolValue == true)
        }
        return CloudLinkedAccounts(accounts: accounts, limit: body["limit"]?.intValue)
    }

    static func accountLink(_ body: JSONValue, fallback: String) -> CloudAccountLink {
        CloudAccountLink(
            accountId: body["account_id"]?.stringValue ?? fallback, linkedAt: body["linked_at"]?.stringValue,
            alreadyLinked: body["already_linked"]?.boolValue == true)
    }
}

// MARK: - Owner node addresses

/// The addresses a fleet node can dial to ask this node for admission, from
/// ``AdminApi/getNetworkStatus()`` (bare, or in its `{data}` wrapper): each
/// `externalAddrs` multiaddr made to end in `/p2p/<localPeerId>`. Anything not
/// a multiaddr is dropped; duplicates once. Empty when there is no peer id or
/// no external address — an honest "not dialable yet".
/// (== mero-js `admitterAddrsFromNetworkStatus`.)
public func admitterAddrsFromNetworkStatus(_ status: JSONValue?) -> [String] {
    guard let status, status.objectValue != nil else { return [] }
    let record = status["data"].flatMap { $0.objectValue != nil ? $0 : nil } ?? status
    guard let peerId = record["localPeerId"]?.stringValue, !peerId.isEmpty,
        let external = record["externalAddrs"]?.arrayValue
    else { return [] }
    let suffix = "/p2p/\(peerId)"
    var out: [String] = []
    for entry in external {
        guard let raw = entry.stringValue else { continue }
        let addr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addr.hasPrefix("/") else { continue }
        let dialable = addr.hasSuffix(suffix) ? addr : addr + suffix
        if !out.contains(dialable) { out.append(dialable) }
    }
    return out
}
