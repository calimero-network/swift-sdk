import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Signing in to Calimero Cloud instead of connecting to a node, and getting a
// relay to write through. Port of mero-js `src/cloud/connect.ts`.
//
// `connectCloud` signs in with a cloud login (a stored MDMA token or a Google
// ID token), picks the namespace the user owns, and the relay the cloud says
// can run an intent there. `connectCloudWithAccount` reaches the same place by
// the other door: the account root signs in as the account itself. Both end in
// the ``CloudConnection`` ``CloudSignIn/connect(_:)`` returns, with the cloud
// fields set: writes go straight to the relay as warrants; the cloud is only
// the directory, and never sees an intent.

/// What ``connectCloud(_:)`` needs. (== mero-js `ConnectCloudOptions`.)
public struct ConnectCloudOptions: Sendable {
    /// The manager URL, and how the relay session is bound (audience, the
    /// relay key verifier, `clientName`, warrant lifetime).
    public var config: CloudConfig
    /// A stored MDMA session token. Give this, ``googleIdToken``, or a
    /// ``sessionStore`` that holds one.
    public var sessionToken: String?
    /// A Google ID token to exchange for a session when no ``sessionToken``
    /// is given (it replaces a session ``sessionStore`` holds).
    public var googleIdToken: String?
    /// Where the login session is kept; see ``CloudClient``.
    public var sessionStore: AnyValueStore<CloudLoginSession>?
    /// Every new or rolling-refreshed session, and `nil` on sign-out.
    public var onSession: (@Sendable (CloudLoginSession?) -> Void)?
    /// Whose writes these are, 64 hex.
    public var authorAccount: String
    /// The author's `AccountProof<DeviceCert>`, hex.
    public var authorProof: String
    /// The certified device's keys; they sign every warrant. Never sent.
    public var keys: DeviceKeys
    /// Which namespace to write in — optional only when the user owns one.
    public var namespaceId: String?
    /// Warrant nonces, persisted so a relaunch continues the sequence.
    public var nonces: any WarrantNonceStore
    /// The relay node's signing key, if known out of band. Otherwise the key
    /// the cloud reports, and failing that the key the relay attests
    /// (``CloudConfig/relayKeyVerifier``). Needed for reads and events only.
    public var relayNodeKey: String?
    /// Where the relay session's tokens are kept.
    public var tokenStore: any TokenStore
    public var urlSession: URLSession
    /// Per-request timeout for the cloud calls.
    public var timeout: TimeInterval
    /// Seal every call to the relay to its attested TEE, verified with this
    /// — for example ``createSignedReleaseVerifier(_:)``, or
    /// ``createQuoteVerifier(_:)`` with the measurements you trust. The
    /// warrant and the method's arguments (and the relay login, its reads and
    /// events) then reach only the relay's TD, not whatever terminates TLS in
    /// front of it, and the relay is one this client checked itself rather
    /// than one the cloud vouched for. Calls to the cloud are not sealed;
    /// they carry no intent. Without it, calls to the relay are plain HTTPS.
    /// (== mero-js `ConnectCloudOptions.seal`.)
    public var seal: (any TransportQuoteVerifier)?

    public init(
        authorAccount: String, authorProof: String, keys: DeviceKeys, config: CloudConfig = CloudConfig(),
        sessionToken: String? = nil, googleIdToken: String? = nil,
        sessionStore: AnyValueStore<CloudLoginSession>? = nil,
        onSession: (@Sendable (CloudLoginSession?) -> Void)? = nil, namespaceId: String? = nil,
        nonces: any WarrantNonceStore = WarrantNonces.shared, relayNodeKey: String? = nil,
        tokenStore: any TokenStore = MemoryTokenStore(), urlSession: URLSession = .shared, timeout: TimeInterval = 10,
        seal: (any TransportQuoteVerifier)? = nil
    ) {
        self.seal = seal
        self.config = config
        self.sessionToken = sessionToken
        self.googleIdToken = googleIdToken
        self.sessionStore = sessionStore
        self.onSession = onSession
        self.authorAccount = authorAccount
        self.authorProof = authorProof
        self.keys = keys
        self.namespaceId = namespaceId
        self.nonces = nonces
        self.relayNodeKey = relayNodeKey
        self.tokenStore = tokenStore
        self.urlSession = urlSession
        self.timeout = timeout
    }
}

/// What ``connectCloudWithAccount(_:)`` needs: a root instead of a cloud
/// login. (== mero-js `ConnectCloudWithAccountOptions`.)
public struct ConnectCloudWithAccountOptions: Sendable {
    /// The account root — the whole credential; no Google login involved. It
    /// signs the sign-in only: the device keys still sign every warrant.
    public var root: RootSource
    /// Whose writes these are; defaults to the account the root derives.
    public var authorAccount: String?
    public var authorProof: String
    public var keys: DeviceKeys
    public var config: CloudConfig
    public var sessionStore: AnyValueStore<CloudLoginSession>?
    public var onSession: (@Sendable (CloudLoginSession?) -> Void)?
    public var namespaceId: String?
    public var nonces: any WarrantNonceStore
    public var relayNodeKey: String?
    public var tokenStore: any TokenStore
    public var urlSession: URLSession
    public var timeout: TimeInterval
    /// As ``ConnectCloudOptions/seal``.
    public var seal: (any TransportQuoteVerifier)?

    public init(
        root: RootSource, authorProof: String, keys: DeviceKeys, authorAccount: String? = nil,
        config: CloudConfig = CloudConfig(), sessionStore: AnyValueStore<CloudLoginSession>? = nil,
        onSession: (@Sendable (CloudLoginSession?) -> Void)? = nil, namespaceId: String? = nil,
        nonces: any WarrantNonceStore = WarrantNonces.shared, relayNodeKey: String? = nil,
        tokenStore: any TokenStore = MemoryTokenStore(), urlSession: URLSession = .shared, timeout: TimeInterval = 10,
        seal: (any TransportQuoteVerifier)? = nil
    ) {
        self.seal = seal
        self.root = root
        self.authorAccount = authorAccount
        self.authorProof = authorProof
        self.keys = keys
        self.config = config
        self.sessionStore = sessionStore
        self.onSession = onSession
        self.namespaceId = namespaceId
        self.nonces = nonces
        self.relayNodeKey = relayNodeKey
        self.tokenStore = tokenStore
        self.urlSession = urlSession
        self.timeout = timeout
    }
}

/// Sign in to the cloud and return a connection that can write.
///
/// Throws rather than returning a half-usable connection:
/// ``AccountError/cloudNotReady(_:)`` says which step is missing — no
/// namespace, several to choose between, HA off, nothing assigned yet, only
/// replicas, or relays waiting for the authorship grant.
public func connectCloud(_ options: ConnectCloudOptions) async throws -> CloudConnection {
    let stored = options.sessionStore?.load()
    guard options.sessionToken != nil || options.googleIdToken != nil || stored != nil else {
        throw AccountError.invalidInput("connectCloud needs either a sessionToken or a googleIdToken")
    }
    let cloud = CloudClient(
        baseURL: options.config.cloudBaseURL, sessionToken: options.sessionToken, sessionStore: options.sessionStore,
        onSession: options.onSession, session: options.urlSession, timeout: options.timeout)
    if options.sessionToken == nil, let idToken = options.googleIdToken {
        try await cloud.signInWithGoogle(idToken)
    }
    return try await CloudConnection.connect(through: cloud, options)
}

/// The same connection, opened with an account root: the root signs in
/// (``CloudClient/signInWithAccount(_:)``), and everything after is
/// ``connectCloud(_:)``. The author defaults to the account the root derives.
public func connectCloudWithAccount(_ options: ConnectCloudWithAccountOptions) async throws -> CloudConnection {
    let resolved = try resolveRoot(options.root)
    let cloud = CloudClient(
        baseURL: options.config.cloudBaseURL, sessionStore: options.sessionStore, onSession: options.onSession,
        session: options.urlSession, timeout: options.timeout)
    try await cloud.signInWithAccount(.signer(resolved.signer))
    let connect = ConnectCloudOptions(
        authorAccount: options.authorAccount ?? resolved.accountId, authorProof: options.authorProof,
        keys: options.keys, config: options.config, namespaceId: options.namespaceId, nonces: options.nonces,
        relayNodeKey: options.relayNodeKey, tokenStore: options.tokenStore, urlSession: options.urlSession,
        timeout: options.timeout, seal: options.seal)
    return try await CloudConnection.connect(through: cloud, connect)
}

// MARK: - Opening a relay session

/// What opening a relay session needs beyond the ``CloudSession``.
struct RelaySessionContext: Sendable {
    let config: CloudConfig
    let keys: DeviceKeys
    let tokenStore: any TokenStore
    let nonces: any WarrantNonceStore
    /// For the attestation, which is never sealed.
    let urlSession: URLSession
    /// For everything else sent to the relay: `urlSession`, or the relay's sealed session.
    let relaySession: URLSession

    init(
        config: CloudConfig, keys: DeviceKeys, tokenStore: any TokenStore, nonces: any WarrantNonceStore,
        urlSession: URLSession, relaySession: URLSession? = nil
    ) {
        self.config = config
        self.keys = keys
        self.tokenStore = tokenStore
        self.nonces = nonces
        self.urlSession = urlSession
        self.relaySession = relaySession ?? urlSession
    }
}

extension CloudConnection {
    /// The namespace writes land in, when the connection came from the cloud
    /// directory (``connectCloud(_:)``).
    public var namespaceId: String? { namespace?.namespaceId }

    /// Run one method in one context through the relay, on the author's behalf.
    public func execute(contextId: String, method: String, argsJson: JSONValue = [:]) async throws -> IntentResult {
        guard let relay else {
            throw AccountError.notSignedIn(readNote ?? "no relay serves this account yet, so there is nowhere to write")
        }
        return try await relay.execute(contextId: contextId, method: method, argsJson: argsJson)
    }

    /// A relay ``RelayClient`` for writes always, and — once the relay's node
    /// key is known (`nodeKey`) or attested — a Bearer ``Mero`` for reads and
    /// events. Shared by ``CloudSignIn/connect(_:)`` and ``connectCloud(_:)``.
    static func open(
        _ session: CloudSession, nodeKey known: String?, context: RelaySessionContext
    ) async -> CloudConnection {
        guard let relayUrl = session.relayUrl else {
            return CloudConnection(session: session, relay: nil, mero: nil, nodeKey: nil, readNote: session.note)
        }
        let config = context.config
        let mero: Mero?
        let nodeKey: String?
        var readNote: String?
        do {
            let key: String
            if let known {
                key = known
            } else {
                key = try await RelayNodeKey.attest(
                    relayURL: relayUrl, verifier: config.relayKeyVerifier, session: context.urlSession)
            }
            let tokens = try await RelayLogin.login(
                relayURL: relayUrl, nodeKey: key, credential: session.credential, keys: context.keys,
                audience: config.audience, clientName: config.clientName, session: context.relaySession)
            guard let base = URL(string: relayUrl) else { throw AccountError.invalidInput("bad relay URL") }
            let client = Mero(
                config: MeroConfig(baseURL: base, tokenStore: context.tokenStore), session: context.relaySession)
            await client.setTokenData(tokens)
            mero = client
            nodeKey = key
        } catch {
            mero = nil
            nodeKey = nil
            readNote =
                "Writes work; reads and live events are off until the relay's session is established: "
                + "\((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        let tokenSource = mero
        let relay = RelayClient(
            relayURL: relayUrl, authorAccount: session.account, authorProof: session.credential, keys: context.keys,
            nonces: context.nonces, executorAccount: session.executorAccount, ttlSeconds: config.warrantTTLSeconds,
            tokenProvider: { await tokenSource?.currentTokenData()?.accessToken }, session: context.relaySession)
        return CloudConnection(session: session, relay: relay, mero: mero, nodeKey: nodeKey, readNote: readNote)
    }

    /// The directory half of ``connectCloud(_:)``, with a signed-in `cloud`.
    static func connect(through cloud: CloudClient, _ options: ConnectCloudOptions) async throws -> CloudConnection {
        let namespace = try pickNamespace(try await cloud.getMyNamespaces(), requested: options.namespaceId)
        // One read for both the choice and the diagnostic: a second could
        // disagree with the first.
        let relays = try await cloud.getNamespaceRelays(namespace.namespaceId)
        guard let relayInfo = CloudClient.pickExecutingRelay(relays) else {
            throw AccountError.cloudNotReady(explainNoRelay(namespace, relays))
        }
        let session = CloudSession(
            account: options.authorAccount.lowercased(),
            device: (try? DeviceCertificates.parse(options.authorProof))?.device ?? "",
            credential: options.authorProof, relayUrl: relayInfo.relayUrl,
            executorAccount: relayInfo.executorAccount)
        // Only the relay is sealed: a sealed transport is bound to one node and
        // refuses any other URL, and the cloud calls above carry no intent.
        var sealed: URLSession?
        if let verifier = options.seal, let relayUrl = relayInfo.relayUrl, let base = URL(string: relayUrl) {
            let transport = try SealedTransport.attested(baseURL: base, verifier: verifier, session: options.urlSession)
            sealed = transport.urlSession()
        }
        let context = RelaySessionContext(
            config: options.config, keys: options.keys, tokenStore: options.tokenStore, nonces: options.nonces,
            urlSession: options.urlSession, relaySession: sealed)
        let opened = await open(session, nodeKey: options.relayNodeKey ?? relayInfo.nodeKey, context: context)
        return CloudConnection(
            session: opened.session, relay: opened.relay, mero: opened.mero, nodeKey: opened.nodeKey,
            readNote: opened.readNote, presence: opened.presence, cloud: cloud, namespace: namespace,
            relayInfo: relayInfo)
    }

    /// The one namespace to write in, or an error naming the ambiguity.
    static func pickNamespace(_ namespaces: [CloudNamespace], requested: String?) throws -> CloudNamespace {
        let owned = namespaces.map(\.namespaceId)
        if let requested {
            guard let found = namespaces.first(where: { $0.namespaceId == requested }) else {
                let list = owned.isEmpty ? "(none)" : owned.joined(separator: ", ")
                throw AccountError.cloudNotReady("this account owns no namespace \(requested); it owns: \(list)")
            }
            return found
        }
        guard let only = namespaces.first else {
            throw AccountError.cloudNotReady(
                "this account owns no namespaces in the cloud: claim one first, then enable HA on it so a relay is "
                    + "assigned")
        }
        guard namespaces.count == 1 else {
            throw AccountError.cloudNotReady(
                "this account owns \(namespaces.count) namespaces — pass namespaceId to say which: "
                    + owned.joined(separator: ", "))
        }
        return only
    }

    /// Why no relay can write here — each state a different ask of the user.
    static func explainNoRelay(_ namespace: CloudNamespace, _ relays: [CloudRelay]) -> String {
        let ns = namespace.namespaceId
        if relays.isEmpty {
            return namespace.haStatus == "enabled"
                ? "namespace \(ns) has HA enabled but no relay has been assigned to it yet — retry shortly"
                : "namespace \(ns) has no relays: enable HA on it in the cloud to have an attested node assigned"
        }
        let replicas = relays.filter { $0.teeRole != nil && $0.teeRole != "RelayTee" }
        if replicas.count == relays.count {
            return [
                "every node on namespace \(ns) is a read-only TEE replica (ReadOnlyTee), which never relays ",
                "delegated writes: an admin of the namespace must set its TEE admission policy with mode: 'relay' ",
                "— AdminApi.setTeeAdmissionPolicy(_:request:) — so fleet nodes are admitted as RelayTee",
            ].joined()
        }
        let waiting = relays.filter { $0.teeRole == nil && !$0.authorshipReady }
        if !waiting.isEmpty, waiting.count + replicas.count == relays.count {
            let names = waiting.map { $0.executorAccount ?? $0.peerId }.joined(separator: ", ")
            let grantee = names.isEmpty ? "the relay account" : names
            return [
                "every relay on namespace \(ns) is waiting for the authorship grant: an admin of the namespace ",
                "must grant CAN_AUTHOR_ON_BEHALF to \(grantee) — with AdminApi.grantAuthorship(_:account:) for ",
                "these relays, and AdminApi.openToDelegatedExecution(_:) so relays assigned later need no further op",
            ].joined()
        }
        return [
            "namespace \(ns) has \(relays.count) relay(s), but none is ready to relay yet (a URL, an executor ",
            "account and a recent heartbeat) — retry shortly",
        ].joined()
    }
}
