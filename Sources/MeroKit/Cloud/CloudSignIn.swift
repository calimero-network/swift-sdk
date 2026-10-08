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

    public init(
        config: CloudConfig = CloudConfig(),
        keyStore: AnyValueStore<DeviceKeys>,
        sessionStore: AnyValueStore<CloudSession>,
        tokenStore: any TokenStore = MemoryTokenStore(),
        nonces: any WarrantNonceStore = UserDefaultsWarrantNonceStore(),
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.keyStore = keyStore
        self.sessionStore = sessionStore
        self.tokenStore = tokenStore
        self.nonces = nonces
        self.urlSession = urlSession
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
        guard let relayUrl = session.relayUrl else {
            return CloudConnection(session: session, relay: nil, mero: nil, nodeKey: nil, readNote: session.note)
        }
        let keys = deviceKeys()
        let mero: Mero?
        let nodeKey: String?
        var readNote: String?
        do {
            let key = try await RelayNodeKey.attest(
                relayURL: relayUrl, verifier: config.relayKeyVerifier, session: urlSession)
            let tokens = try await RelayLogin.login(
                relayURL: relayUrl, nodeKey: key, credential: session.credential, keys: keys,
                audience: config.audience, clientName: config.clientName, session: urlSession)
            guard let base = URL(string: relayUrl) else { throw AccountError.invalidInput("bad relay URL") }
            let client = Mero(config: MeroConfig(baseURL: base, tokenStore: tokenStore), session: urlSession)
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
            relayURL: relayUrl, authorAccount: session.account, authorProof: session.credential, keys: keys,
            nonces: nonces, executorAccount: session.executorAccount, ttlSeconds: config.warrantTTLSeconds,
            tokenProvider: { await tokenSource?.currentTokenData()?.accessToken }, session: urlSession)
        return CloudConnection(session: session, relay: relay, mero: mero, nodeKey: nodeKey, readNote: readNote)
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
