import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where Cloud sign-in goes, and how it binds the relay session.
public struct CloudConfig: Sendable {
    /// The wallet's enrolment page.
    public var walletURL: URL
    /// The Cloud manager (relay discovery, namespace routing).
    public var cloudBaseURL: URL
    /// What the relay login statement binds the session to.
    public var audience: LoginAudience
    /// `client_name` on the relay token request (defaults to the relay URL).
    public var clientName: String?
    /// Decides whether to trust a relay's attested node key.
    public var relayKeyVerifier: any RelayKeyVerifier
    /// Warrant lifetime.
    public var warrantTTLSeconds: UInt64

    public init(
        walletURL: URL = DeviceEnrolment.defaultWalletURL, cloudBaseURL: URL = CloudClient.defaultBaseURL,
        audience: LoginAudience = .current, clientName: String? = nil,
        relayKeyVerifier: any RelayKeyVerifier = TLSRelayKeyVerifier(), warrantTTLSeconds: UInt64 = 300
    ) {
        self.walletURL = walletURL
        self.cloudBaseURL = cloudBaseURL
        self.audience = audience
        self.clientName = clientName
        self.relayKeyVerifier = relayKeyVerifier
        self.warrantTTLSeconds = warrantTTLSeconds
    }
}

/// A signed-in Cloud account on this device. Persisted (by
/// ``CloudSignIn``'s session store) so a relaunch skips the wallet.
public struct CloudSession: Codable, Sendable, Equatable {
    /// The account, 64 hex.
    public var account: String
    /// This device's id within it, 64 hex.
    public var device: String
    /// The device certificate (`AccountProof<DeviceCert>`), hex.
    public var credential: String
    /// The relay that serves the account, or `nil` — still signed in: a new
    /// account earns a relay by redeeming an invitation.
    public var relayUrl: String?
    /// The relay's own account, when the cloud named it.
    public var executorAccount: String?
    /// Something worth showing about how the relay was chosen.
    public var note: String?

    public init(
        account: String, device: String, credential: String, relayUrl: String? = nil, executorAccount: String? = nil,
        note: String? = nil
    ) {
        self.account = account
        self.device = device
        self.credential = credential
        self.relayUrl = relayUrl
        self.executorAccount = executorAccount
        self.note = note
    }

    /// Signed in, but with no relay to talk through yet.
    public var isRelayless: Bool { relayUrl == nil }
}

/// A live connection to the account's relay.
public struct CloudConnection: Sendable {
    public let session: CloudSession
    /// Warranted writes (and reads by query). `nil` when relayless.
    public let relay: RelayClient?
    /// A ``Mero`` pointed at the relay, holding the `account_proof` Bearer
    /// session: admin reads and SSE. `nil` when relayless, or when the relay's
    /// node key could not be established (see ``readNote``).
    public let mero: Mero?
    /// The relay's node key the session is bound to.
    public let nodeKey: String?
    /// Why reads are unavailable, when they are.
    public let readNote: String?
    /// The account's presence through the relay: device-signed updates,
    /// resent every 2.5 s while set, read off ``mero``'s ``Mero/sse``.
    /// `nil` when relayless.
    public let presence: RelayPresenceClient?
    /// The signed-in cloud API (namespaces, HA, linking, sign-out), when the
    /// connection came from ``connectCloud(_:)``; `nil` from ``CloudSignIn``.
    public let cloud: CloudClient?
    /// The owned namespace writes land in (``connectCloud(_:)`` only).
    public let namespace: CloudNamespace?
    /// What the cloud reported about the chosen relay (``connectCloud(_:)`` only).
    public let relayInfo: CloudRelay?

    public init(
        session: CloudSession, relay: RelayClient?, mero: Mero?, nodeKey: String?, readNote: String?,
        presence: RelayPresenceClient? = nil, cloud: CloudClient? = nil, namespace: CloudNamespace? = nil,
        relayInfo: CloudRelay? = nil
    ) {
        self.session = session
        self.relay = relay
        self.mero = mero
        self.nodeKey = nodeKey
        self.readNote = readNote
        self.cloud = cloud
        self.namespace = namespace
        self.relayInfo = relayInfo
        self.presence =
            presence
            ?? relay.map { relay in
                RelayPresenceClient(relay: relay, events: { mero?.sse })
            }
    }
}

/// Cloud sign-in, end to end, for a native app:
///
/// 1. ``beginEnrolment(callbackURL:)`` — device keys (created once, kept in the
///    key store) and the wallet URL to open in the system auth sheet.
/// 2. ``completeEnrolment(callbackURL:)`` — verify the credential the wallet
///    returned, ask the Cloud manager which relay serves the account, persist.
/// 3. ``connect(_:)`` — attest the relay's node key, log in there with the
///    device certificate, and hand back a relay ``Mero`` + ``RelayClient``.
///
/// The presentation (ASWebAuthenticationSession) lives in MeroKitUI; this type
/// is UI-free so it can be driven from tests and from any UI framework.
public actor CloudSignIn {
    public let config: CloudConfig
    private let keyStore: AnyValueStore<DeviceKeys>
    private let sessionStore: AnyValueStore<CloudSession>
    private let tokenStore: any TokenStore
    private let nonces: any WarrantNonceStore
    private let urlSession: URLSession
    private var pendingState: String?
    /// The account's relay map, subgroup namespaces and pinned relay keys.
    public let delegatedStore: DelegatedAccountStore

    public init(
        config: CloudConfig = CloudConfig(),
        keyStore: AnyValueStore<DeviceKeys>,
        sessionStore: AnyValueStore<CloudSession>,
        tokenStore: any TokenStore = MemoryTokenStore(),
        nonces: any WarrantNonceStore = UserDefaultsWarrantNonceStore(),
        urlSession: URLSession = .shared,
        delegatedStore: DelegatedAccountStore = .shared
    ) {
        self.config = config
        self.keyStore = keyStore
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.nonces = nonces
        self.urlSession = urlSession
        self.delegatedStore = delegatedStore
    }

    /// What the ``DelegatedAccounts`` helpers run with for this sign-in.
    public nonisolated var delegatedEnvironment: DelegatedEnvironment {
        DelegatedEnvironment(config, store: delegatedStore, nonces: nonces, urlSession: urlSession)
    }

    /// The signed-in session as a ``DelegatedSession`` (this device's keys).
    public func delegatedSession() -> DelegatedSession? {
        sessionStore.load().map { DelegatedSession($0, keys: deviceKeys()) }
    }

    #if canImport(Security)
    /// Keychain-backed device keys, session and tokens; nonces in `UserDefaults`.
    public static func keychain(
        config: CloudConfig = CloudConfig(), service: String = "network.calimero.merokit",
        accessGroup: String? = nil, urlSession: URLSession = .shared
    ) -> CloudSignIn {
        CloudSignIn(
            config: config,
            keyStore: .keychain(account: "cloud-device-keys", service: service, accessGroup: accessGroup),
            sessionStore: .keychain(account: "cloud-session", service: service, accessGroup: accessGroup),
            tokenStore: KeychainTokenStore(service: service, account: "cloud-relay-tokens", accessGroup: accessGroup),
            urlSession: urlSession)
    }
    #endif

    /// This device's keys, created on first use.
    public func deviceKeys() -> DeviceKeys {
        DeviceKeys.loadOrCreate(in: keyStore)
    }

    /// The session from a previous launch, if any.
    public func restoreSession() -> CloudSession? {
        sessionStore.load()
    }

    // MARK: - Enrolment

    /// The wallet URL to open, naming this device's keys and `callbackURL`.
    /// Remembers a fresh `state` to compare on return.
    public func beginEnrolment(callbackURL: String) throws -> URL {
        let keys = deviceKeys()
        let state = DeviceEnrolment.makeState()
        let url = try DeviceEnrolment.url(
            walletURL: config.walletURL, devicePublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey,
            callbackURL: callbackURL, state: state)
        pendingState = state
        return url
    }

    /// Verify the wallet's answer, find the account's relay, and persist the
    /// session. Throws ``AccountError`` for a declined, foreign or invalid
    /// enrolment — nothing is stored then.
    @discardableResult
    public func completeEnrolment(callbackURL: URL) async throws -> CloudSession {
        guard let callback = try DeviceEnrolment.readCallback(callbackURL) else {
            throw AccountError.protocolViolation("the wallet returned no credential")
        }
        return try await completeEnrolment(callback)
    }

    /// As ``completeEnrolment(callbackURL:)``, from an already-parsed callback.
    @discardableResult
    public func completeEnrolment(_ callback: EnrolmentCallback) async throws -> CloudSession {
        let keys = deviceKeys()
        let enrolled = try DeviceEnrolment.completeEnrolment(callback, keys: keys, expectState: pendingState)
        pendingState = nil

        var session = CloudSession(account: enrolled.account, device: enrolled.device, credential: enrolled.credential)
        do {
            let relays = try await cloudClient(keys: keys, credential: enrolled.credential)
                .getAccountRelays(enrolled.account)
            let choice = CloudClient.chooseRelay(relays)
            session.relayUrl = choice.relayUrl
            session.executorAccount = choice.executorAccount
            session.note = choice.note
        } catch {
            session.note =
                "Signed in, but the Cloud manager could not be asked for a relay: "
                + "\((error as? LocalizedError)?.errorDescription ?? "\(error)"). Try again shortly."
        }
        sessionStore.save(session)
        return session
    }

    /// Ask the Cloud manager again for the account's relay (e.g. after a join).
    @discardableResult
    public func refreshRelay() async throws -> CloudSession {
        guard var session = sessionStore.load() else { throw AccountError.notSignedIn("not signed in") }
        let relays = try await cloudClient(keys: deviceKeys(), credential: session.credential)
            .getAccountRelays(session.account)
        let choice = CloudClient.chooseRelay(relays)
        session.relayUrl = choice.relayUrl ?? session.relayUrl
        session.executorAccount = choice.executorAccount ?? session.executorAccount
        session.note = choice.note
        sessionStore.save(session)
        return session
    }

    // MARK: - Relay session

    /// Connect to the session's relay: a ``RelayClient`` for writes always, and
    /// — once the relay's node key is established — a Bearer ``Mero`` for
    /// admin reads and events.
    public func connect(_ session: CloudSession) async -> CloudConnection {
        await CloudConnection.open(
            session, nodeKey: nil,
            context: RelaySessionContext(
                config: config, keys: deviceKeys(), tokenStore: tokenStore, nonces: nonces, urlSession: urlSession))
    }

    // MARK: - Join

    /// Redeem a namespace invitation as this account: resolve the admitting
    /// relay through the Cloud manager, sign the join, and send it. A relayless
    /// session adopts the admitting relay.
    @discardableResult
    public func join(
        namespaceId: String, invitation: SignedGroupOpenInvitation, nodeURL: String? = nil
    ) async throws -> (session: CloudSession, outcome: JoinOutcome) {
        guard var session = sessionStore.load() else { throw AccountError.notSignedIn("not signed in") }
        let keys = deviceKeys()
        let outcome = try await AccountJoin.bootstrapFromInvitation(
            namespaceId: namespaceId, invitation: invitation, account: session.account,
            credential: session.credential, keys: keys, nonce: nonces.next(relay: "join:\(session.account)"),
            nodeURL: nodeURL, cloud: cloudClient(keys: keys, credential: session.credential), session: urlSession)
        if session.relayUrl == nil {
            session.relayUrl = outcome.relayUrl
            session.note = nil
            sessionStore.save(session)
        }
        return (session, outcome)
    }

    // MARK: - Found a namespace

    /// Found a namespace as the account, through the session's relay, and set
    /// it up the way mero-react's `createNamespace` does: the application it
    /// runs (resolved from the registry unless given), a default capability
    /// mask, a name, and — when the relay attested the founding — HA in the
    /// cloud so the fleet can host it.
    ///
    /// ``DelegatedAccounts/foundDelegatedNamespace(_:defaultCapabilities:application:env:)``
    /// does the founding: the relay's executor key is its node key **attested
    /// now**, its account the cloud's (`executor_account`) or else discovery's
    /// on a namespace the account is in there, checked against that key. The
    /// namespaces the relay session lists are recorded first, so a session
    /// with no executor still finds one.
    ///
    /// HA is best-effort (`haEnabled`/`haError`): the namespace exists whatever
    /// the cloud answers. A namespace that could not be given its application
    /// throws, since no context could be created in it.
    public func foundNamespace(
        _ connection: CloudConnection, name: String? = nil, package: String,
        application: FoundingApplication? = nil,
        defaultCapabilities: UInt32? = CloudSignIn.defaultNamespaceCapabilities,
        registryURL: String = ApplicationRegistry.defaultURL
    ) async throws -> FoundedDelegatedNamespace {
        guard let relayUrl = connection.session.relayUrl, connection.relay != nil else {
            throw AccountError.notSignedIn(
                "no relay serves this account yet, so there is nowhere to found a namespace: join from an invitation first"
            )
        }
        let session = DelegatedSession(connection.session, keys: deviceKeys())
        if session.executorAccount == nil, let listed = try? await connection.mero?.admin.listNamespaces() {
            for namespace in listed {
                delegatedStore.rememberRelay(
                    account: session.account, relayURL: relayUrl, namespaceId: namespace.namespaceId)
            }
        }
        let app: FoundingApplication
        if let application {
            app = application
        } else {
            let resolved = try await ApplicationRegistry.resolve(
                registryURL: registryURL, package: package, session: urlSession)
            app = FoundingApplication(
                applicationId: resolved.applicationId, package: package, version: resolved.version)
        }
        let env = delegatedEnvironment
        let founded = try await DelegatedAccounts.foundDelegatedNamespace(
            session, defaultCapabilities: defaultCapabilities, application: app, env: env)
        if let name, !name.isEmpty {
            try await DelegatedAccounts.governGroup(
                session, groupId: founded.namespaceId, op: GovernanceOps.groupMetadataSet(name: name), env: env)
        }
        return founded
    }

    /// What mero-react founds a namespace with: create contexts, invite, join
    /// open subgroups, create/delete subgroups, manage visibility and metadata.
    public static let defaultNamespaceCapabilities: UInt32 = 231

    // MARK: - Invite

    /// Mint an invitation to `namespaceId` as the account, signed with this
    /// device's key — no node involved. Port of mero-js
    /// `createAccountAdmin().createNamespaceInvitation`
    /// (``AccountAdmin/mintInvitation(namespaceId:session:read:routing:invitedRole:validForSeconds:sign:)``).
    ///
    /// The namespace's TEE relays are named as admitters (only a relay can
    /// admit a joiner with no node); with none, its admins. An invitation
    /// nobody could claim is refused
    /// (``AccountError/invitationNotClaimable(namespaceId:reason:)``): the cloud
    /// lists no node holding the namespace (`not-hosted` — an address on the
    /// invitation is unsigned, so it cannot stand in), or none it would name
    /// (`no-named-node`).
    public func createNamespaceInvitation(
        _ connection: CloudConnection, namespaceId: String, invitedRole: GroupInvitations.InvitedRole = .member,
        validForSeconds: Int = GroupInvitations.maxValiditySeconds
    ) async throws -> SignedGroupOpenInvitation {
        guard let mero = connection.mero else {
            throw AccountError.relayKeyUnavailable(
                "reading the namespace's members needs the relay session, which is not established: "
                    + (connection.readNote ?? "no relay"))
        }
        let cloud = cloudClient(keys: deviceKeys(), credential: connection.session.credential)
        return try await AccountAdmin.mintInvitation(
            namespaceId: namespaceId, session: DelegatedSession(connection.session, keys: deviceKeys()),
            read: await mero.admin, routing: { try await cloud.getNamespaceRouting($0).nodes.map(\.account) },
            invitedRole: invitedRole, validForSeconds: validForSeconds)
    }

    /// A ``CloudClient`` proving reads with this device's certificate.
    public func cloudClient() throws -> CloudClient {
        guard let session = sessionStore.load() else { throw AccountError.notSignedIn("not signed in") }
        return cloudClient(keys: deviceKeys(), credential: session.credential)
    }

    // MARK: - Sign out

    /// Retire the relay session (`POST /auth/logout`), then forget the account.
    /// The device keys stay unless `forgetDevice`.
    public func signOut(forgetDevice: Bool = false) async {
        if let relayUrl = sessionStore.load()?.relayUrl, let tokens = tokenStore.getTokens() {
            await RelayLogin.logout(relayURL: relayUrl, refreshToken: tokens.refreshToken, session: urlSession)
        }
        tokenStore.clear()
        sessionStore.clear()
        pendingState = nil
        if forgetDevice { keyStore.clear() }
    }

    private func cloudClient(keys: DeviceKeys, credential: String) -> CloudClient {
        CloudClient(
            baseURL: config.cloudBaseURL,
            routingCredential: RoutingCredential(credential: credential, deviceSecret: keys.signSecret),
            session: urlSession)
    }
}

/// What ``CloudSignIn/foundNamespace(_:name:package:application:defaultCapabilities:registryURL:)`` returns.
public struct FoundedDelegatedNamespace: Sendable, Equatable {
    public let namespaceId: String
    /// Keep it to prove founding later: `(account, salt)` reproduces the id.
    public let salt: String
    public let teeEnabled: Bool
    /// Whether the cloud agreed to host the namespace (HA) right after founding.
    public let haEnabled: Bool
    /// Why `haEnabled` is false, in words a person can act on.
    public let haError: String?
    /// `nil` when no mask was asked for.
    public let defaultCapabilitiesSet: Bool?
}
