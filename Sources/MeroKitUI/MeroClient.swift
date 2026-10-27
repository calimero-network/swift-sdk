import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Observable frontend view-model wrapping ``Mero`` — the native analog of
/// mero-react's `MeroProvider` / `useMero`. Inject it via `.environmentObject`
/// and bind SwiftUI views to its `@Published` state.
///
/// Two ways in, as in mero-react:
///
/// - **An account** (``signInWithCloud(callbackScheme:)``, or
///   ``connectWithAccount(_:)`` with a ``DelegatedSession`` you hold): the
///   Calimero wallet certifies this device, and the client writes through the
///   relay that serves the account. ``isDelegated`` is `true`, ``admin`` is an
///   ``AccountAdmin``.
/// - **A node login** (``connectToNode(_:callback:)``): the node's own login
///   page in the system auth sheet, returning tokens the client adopts only
///   from a node it chose (``NodeTrust``, ``TokenAdoption``). ``admin`` is a
///   ``NodeAdmin``; ``isOnline`` follows the node's event stream.
///
/// ``login(nodeURL:username:password:)`` remains for talking to a development
/// node directly.
///
/// A custom `URLSession` can be injected (used by UI tests to route through a
/// mock backend), mirroring the SDK's own testability hook.
@MainActor
public final class MeroClient: ObservableObject {
    @Published public private(set) var isAuthenticated = false
    @Published public private(set) var isLoading = false
    /// Whether the connection is up: a node's event stream is connected. An
    /// account's session is reported online. (== mero-react `isOnline`.)
    @Published public private(set) var isOnline = true
    /// The node (or relay) this client talks to.
    @Published public private(set) var nodeURL: String = ""
    /// A display name: the username for a node login, a short account id for Cloud.
    @Published public private(set) var username: String = ""
    @Published public private(set) var errorMessage: String?
    /// Why the last ``login(nodeURL:username:password:)`` failed, typed, next
    /// to its ``errorMessage``: a wrong password, a lockout (with the node's
    /// `Retry-After`), no node at the URL... `nil` after a success, a
    /// ``clearError()`` or a ``logout()``.
    @Published public private(set) var loginFailure: LoginFailureReason?
    @Published public private(set) var lastRpcResult: String?
    /// Signed in on tokens the node has not confirmed this launch:
    /// ``resumeNodeSession()`` found it unreachable and kept the stored
    /// session. ``isAuthenticated`` is `true` and calls go out with the held
    /// tokens; this clears once the node's event stream connects, and a node
    /// that rejects the tokens logs out.
    @Published public private(set) var isOfflineSession = false

    /// The words ``errorMessage`` shows for an error, in place of the
    /// built-in ones (``defaultMessage(for:)``). Return `nil` to keep the
    /// built-in message for that error. Set it to rebrand or localise.
    public var errorMessages: (@MainActor (Error) -> String?)?

    // MARK: Session state (== mero-react useMero)

    /// The application this session is for: from the SSO callback on a node,
    /// derived from the registry (``MeroProviderConfig/packageName``) or the
    /// account's contexts for an account.
    @Published public private(set) var applicationId: String?
    /// The context the app has open (from the auth flow, or ``selectContext(_:identity:)``).
    @Published public private(set) var contextId: String?
    /// The context identity (executor public key) for ``contextId``.
    @Published public private(set) var contextIdentity: String?
    /// The account session, or `nil` on a node login. (mero-react's delegated record.)
    @Published public private(set) var delegatedSession: DelegatedSession?
    /// The connected client — a node client, or a relay-transport client for
    /// an account. `rpc` is the same call on both. (== mero-react `mero`.)
    @Published public private(set) var transport: MeroTransportClient?
    /// The admin to write against, whatever the session: ``NodeAdmin`` on a
    /// node, ``AccountAdmin`` on an account. `nil` until connected.
    /// (== mero-react `admin`.)
    @Published public private(set) var admin: (any AdminSurface)?
    /// Bumped whenever ``transport`` or ``admin`` is replaced, so bound view
    /// models re-read against the new session.
    @Published public private(set) var sessionRevision = 0

    /// The raw admin client behind ``admin`` — the node's own, or the relay's
    /// caller-scoped one — for calls outside ``AdminSurface`` (blobs,
    /// per-application listings, resync).
    public private(set) var readAdmin: AdminApi?

    // MARK: Cloud session state

    /// The signed-in Cloud account (64 hex), or `nil`.
    @Published public private(set) var account: String?
    /// The relay serving the account, or `nil`.
    @Published public private(set) var relayURL: String?
    /// Signed in, but with no relay yet: a new account earns one by redeeming
    /// an invitation. Not an error.
    @Published public private(set) var isSignedInWithoutRelay = false
    /// Something worth showing about the Cloud session (relay choice, reads off).
    @Published public private(set) var cloudNote: String?
    /// The live relay connection, after a Cloud sign-in.
    public private(set) var connection: CloudConnection?

    /// How this client was configured.
    public let config: MeroProviderConfig
    /// Where node URL and ids persist.
    public let storage: MeroAppStorage
    /// The pending SSO logins ``connectToNode(_:callback:)`` began.
    public let authStateStore: AuthLoginStateStore

    private var mero: Mero?
    private let session: URLSession?
    private let makeTokenStore: @Sendable () -> any TokenStore
    private let cloud: CloudSignIn
    private let webAuthenticator: any WebAuthenticating
    private var healthTask: Task<Void, Never>?
    private var delegatedTask: Task<Void, Never>?
    /// Guards the 401 recovery so a burst of reconnect failures cannot stack
    /// validations over one single-use refresh token.
    private var recovering = false

    public init(
        session: URLSession? = nil,
        tokenStore: @escaping @Sendable () -> any TokenStore = { MemoryTokenStore() },
        cloud: CloudSignIn? = nil,
        webAuthenticator: (any WebAuthenticating)? = nil,
        config: MeroProviderConfig = MeroProviderConfig(),
        storage: MeroAppStorage = .standard,
        authStateStore: AuthLoginStateStore = .shared
    ) {
        self.session = session
        self.makeTokenStore = tokenStore
        self.config = config
        self.storage = storage
        self.authStateStore = authStateStore
        self.cloud =
            cloud
            ?? CloudSignIn(
                config: CloudConfig(cloudBaseURL: config.cloudBaseURL ?? CloudClient.defaultBaseURL),
                keyStore: Self.defaultKeyStore(), sessionStore: Self.defaultSessionStore(),
                urlSession: session ?? .shared, pendingEnrolmentStore: Self.defaultPendingEnrolmentStore())
        #if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
        self.webAuthenticator = webAuthenticator ?? SystemWebAuthenticator()
        #else
        self.webAuthenticator = webAuthenticator ?? UnavailableWebAuthenticator()
        #endif
        applicationId = storage.applicationId
        contextId = storage.contextId
        contextIdentity = storage.contextIdentity
    }

    // MARK: - Derived

    /// Whether this is an account (relay) session rather than a node login.
    /// (== mero-react `isDelegated`.)
    public var isDelegated: Bool { delegatedSession != nil }

    /// What this connection may do. (== mero-react `can`.)
    public var can: MeroCapabilities {
        isDelegated ? .account(hasPackage: config.packageName?.isEmpty == false) : .node
    }

    /// The app's registry identity. (== mero-react `app`.)
    public var app: AdminAppConfig { config.app }

    /// The node client of a node login, or `nil`.
    public var node: Mero? { mero }

    /// The account-layer client behind this view-model (joins, relay refresh).
    public var cloudSignIn: CloudSignIn { cloud }

    /// The environment the account helpers run with.
    public nonisolated var delegatedEnvironment: DelegatedEnvironment { cloud.delegatedEnvironment }

    /// The URL session this client was given (`.shared` by default).
    public var urlSession: URLSession { session ?? .shared }

    // MARK: - Restore

    /// Reconnect whatever the last launch had: the Cloud session first, else
    /// the node in ``storage``. Returns whether a session was restored.
    @discardableResult
    public func restore() async -> Bool {
        if await restoreCloudSession() { return true }
        return await restoreNodeSession()
    }

    /// Reconnect the node in ``storage`` if its stored token still validates.
    /// A node that cannot be reached reads as `false` here, like a rejected
    /// token; ``resumeNodeSession()`` tells the two apart.
    @discardableResult
    public func restoreNodeSession() async -> Bool {
        guard !isAuthenticated, let saved = storage.nodeURL else { return false }
        isLoading = true
        defer { isLoading = false }
        await finishNodeSession(url: saved, instance: nil, fromCallback: false)
        return isAuthenticated
    }

    /// Reconnect the node in ``storage``, keeping the session when the node
    /// cannot be reached — for an app that works offline.
    ///
    /// - ``NodeSessionRestore/restored``: the node accepted the stored token.
    /// - ``NodeSessionRestore/offline``: the node gave no verdict (no network,
    ///   timeout, `5xx`). The held tokens are adopted: ``isAuthenticated`` is
    ///   `true`, ``isOnline`` and ``isOfflineSession`` say the node has not
    ///   been reached, and the event stream keeps trying. A node that later
    ///   rejects the tokens logs out, as for any session.
    /// - ``NodeSessionRestore/rejected``: the node refused the token; sign in again.
    /// - ``NodeSessionRestore/noSession``: no stored node, or no token for it
    ///   (or a session is already up).
    @discardableResult
    public func resumeNodeSession() async -> NodeSessionRestore {
        guard !isAuthenticated, let saved = storage.nodeURL else { return .noSession }
        isLoading = true
        defer { isLoading = false }
        let client = makeNodeMero(saved)
        switch await Self.verifyAuth(client) {
        case .valid:
            await installNode(client, url: saved)
            isAuthenticated = true
            isOnline = true
            isOfflineSession = false
            startHealth(client)
            return .restored
        case .unreachable:
            await installNode(client, url: saved)
            isAuthenticated = true
            isOnline = false
            isOfflineSession = true
            startHealth(client)
            return .offline
        case .rejected:
            return .rejected
        case .noToken:
            return .noSession
        }
    }

    // MARK: - Cloud sign-in

    /// Sign in with the Calimero wallet: open it in the system auth sheet with
    /// a callback on `callbackScheme` (e.g. `"mero-sample"` →
    /// `mero-sample://enrol`), verify what it returns, and connect to the
    /// account's relay. Publishes auth state or an error.
    public func signInWithCloud(callbackScheme: String) async {
        await signInWithCloud(callback: .scheme(callbackScheme))
    }

    /// As ``signInWithCloud(callbackScheme:)``, for any callback (an https
    /// Universal Link with `.https(host:path:)`).
    public func signInWithCloud(callback: CloudCallback) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let walletURL = try await cloud.beginEnrolment(callbackURL: callback.url)
            let returned = try await webAuthenticator.authenticate(url: walletURL, callback: callback)
            try await completeEnrolment(returned)
        } catch is WebAuthenticationCancelled {
            // Dismissing the sheet is a choice, not an error to show.
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Finish a sign-in from a callback URL the app received itself (an https
    /// Universal Link or `onOpenURL`), rather than through the auth sheet.
    /// Returns `false` when the URL carries no enrolment.
    @discardableResult
    public func handleEnrolmentCallback(_ url: URL) async -> Bool {
        guard (try? DeviceEnrolment.readCallback(url)) != nil || url.fragment?.contains("error=") == true else {
            return false
        }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await completeEnrolment(url)
        } catch {
            errorMessage = friendlyMessage(error)
        }
        return true
    }

    /// Reconnect the Cloud session from a previous launch, if any. Returns
    /// whether one was restored.
    ///
    /// The Cloud manager is asked again which relay serves the account
    /// (``CloudSignIn/refreshRelay()``): it may have gained one since, or its
    /// relay moved — an HA rebuild replaces the VM, and the persisted hostname
    /// stops resolving. A lookup that fails keeps the persisted relay, read back
    /// from the store: the failed refresh wrote there what it can no longer vouch
    /// for (a new-account confirmation).
    @discardableResult
    public func restoreCloudSession() async -> Bool {
        guard let stored = await cloud.restoreSession() else { return false }
        isLoading = true
        defer { isLoading = false }
        let session: CloudSession
        if let refreshed = try? await cloud.refreshRelay() {
            session = refreshed
        } else {
            session = await cloud.restoreSession() ?? stored
        }
        await adopt(await cloud.connect(session))
        return true
    }

    private func completeEnrolment(_ url: URL) async throws {
        let stored = try await cloud.completeEnrolment(callbackURL: url)
        await adopt(await cloud.connect(stored))
    }

    private func adopt(_ connection: CloudConnection) async {
        self.connection = connection
        self.mero = connection.mero
        account = connection.session.account
        relayURL = connection.session.relayUrl
        isSignedInWithoutRelay = connection.session.isRelayless
        cloudNote = connection.readNote ?? connection.session.note
        nodeURL = connection.session.relayUrl ?? ""
        username = Self.shortId(connection.session.account)
        isAuthenticated = true
        let env = cloud.delegatedEnvironment
        if let relay = connection.session.relayUrl, let key = connection.nodeKey {
            env.store.pinRelayNodeKey(relayURL: relay, nodeKey: key)
        }
        let session = DelegatedSession(connection.session, keys: await cloud.deviceKeys())
        await installDelegated(session, learnKey: false)
    }

    // MARK: - Accounts (== mero-react connectWithAccount)

    /// Adopt an account connection: an account, a device it certified, and a
    /// relay that writes on its behalf. Usable at once — every request carries
    /// its own credential. A relay whose node key is not known yet is learned
    /// first (``isLoading`` meanwhile), so the app's reads are not sent
    /// unsigned. (== mero-react `connectWithAccount`.)
    ///
    /// The Cloud sign-in persists its session itself (``CloudSignIn``); a
    /// session adopted here lives as long as this client.
    public func connectWithAccount(_ session: DelegatedSession) {
        delegatedTask?.cancel()
        Task { [weak self] in await self?.installDelegated(session, learnKey: true) }
    }

    private func installDelegated(_ session: DelegatedSession, learnKey: Bool) async {
        delegatedTask?.cancel()
        stopHealth()
        let env = cloud.delegatedEnvironment
        delegatedSession = session
        account = session.account
        let relay =
            contextId.flatMap { DelegatedAccounts.relayForContext(session.account, contextId: $0, store: env.store) }
            ?? session.relayUrl
        // Re-routed to the context's relay; the executor account stays only on the same relay.
        let routed = relay == session.relayUrl ? session : session.on(relay: relay)
        let client = try? DelegatedAccounts.buildDelegatedClient(routed, contextId: contextId, env: env)
        let keyUnknown = relay.map { env.store.pinnedRelayNodeKey(relayURL: $0) == nil } ?? false
        let awaitingKey = learnKey && client != nil && keyUnknown
        isAuthenticated = true
        isOnline = true
        nodeURL = relay ?? ""
        if username.isEmpty { username = Self.shortId(session.account) }
        if awaitingKey {
            isLoading = true
            await setDelegatedClient(nil, session: session, hasRelay: true)
        } else {
            await setDelegatedClient(client, session: session, hasRelay: relay != nil)
        }
        delegatedTask = Task { [weak self] in
            if awaitingKey, let relay {
                let key = await DelegatedAccounts.learnRelayNodeKey(relay, env: env)
                guard let self, !Task.isCancelled else { return }
                let rebuilt = key == nil ? client : (try? DelegatedAccounts.buildDelegatedClient(routed, env: env))
                await self.setDelegatedClient(rebuilt ?? client, session: session, hasRelay: true)
                self.isLoading = false
                if key == nil { return }
            }
            guard client != nil else { return }
            await self?.resolveApplicationId(session, env: env)
        }
    }

    /// Publish the relay client and the account admin over it. An account
    /// with no relay gets the empty admin; one still learning its relay's key,
    /// none yet.
    private func setDelegatedClient(_ client: MeroTransportClient?, session: DelegatedSession, hasRelay: Bool) async {
        transport = client
        var read: AdminApi?
        if let client { read = try? await client.admin }
        readAdmin = read
        if !hasRelay || client != nil {
            admin = AccountAdmin(
                session: session, read: read, app: config.app, env: cloud.delegatedEnvironment,
                deps: accountDeps(session))
        } else {
            admin = nil
        }
        sessionRevision += 1
    }

    private func accountDeps(_ session: DelegatedSession) -> AccountAdminDeps {
        let env = cloud.delegatedEnvironment
        let cloudBase = config.cloudBaseURL ?? env.cloudBaseURL
        var deps = AccountAdminDeps.live(env)
        let onJoined: @Sendable (DelegatedSession) -> Void = { [weak self] joined in
            Task { @MainActor [weak self] in self?.connectWithAccount(joined) }
        }
        deps.join = { namespaceId, invitation in
            try await DelegatedAccounts.joinAsAccount(
                session, namespaceId: namespaceId, invitation: invitation, cloudBaseURL: cloudBase, env: env,
                onJoined: onJoined)
        }
        deps.routing = { namespaceId in
            let routing = CloudClient(
                baseURL: cloudBase,
                routingCredential: RoutingCredential(
                    credential: session.credential, deviceSecret: session.keys.signSecret),
                session: env.urlSession)
            return try await routing.getNamespaceRouting(namespaceId).nodes.map(\.account)
        }
        return deps
    }

    /// Which application this session is for, asked rather than told: the
    /// app's registry package decides; without one (or with a registry that
    /// did not answer), the account's contexts — when they name exactly one
    /// application. Not persisted: it is derived from a cheap read.
    private func resolveApplicationId(_ session: DelegatedSession, env: DelegatedEnvironment) async {
        if let package = config.packageName, !package.isEmpty {
            let resolved = try? await ApplicationRegistry.resolve(
                registryURL: config.registryURL ?? ApplicationRegistry.defaultURL, package: package,
                session: env.urlSession)
            if Task.isCancelled { return }
            if let resolved {
                applicationId = resolved.applicationId
                return
            }
        }
        // Every relay down leaves the id unknown, as an empty listing would.
        let contexts = (try? await DelegatedAccounts.listDelegatedContexts(session, env: env)) ?? []
        if Task.isCancelled { return }
        let apps = Set(contexts.map(\.item.applicationId).filter { !$0.isEmpty })
        if apps.count == 1 { applicationId = apps.first }
    }

    // MARK: - Node login (== mero-react connectToNode)

    /// Open `url`'s login page in the system auth sheet, asking for
    /// ``MeroProviderConfig/mode``'s permissions, and adopt the session it
    /// returns. The node is remembered first: it is the trust anchor the
    /// callback is checked against.
    public func connectToNode(_ url: String, callbackScheme: String) async {
        await connectToNode(url, callback: .scheme(callbackScheme, path: "auth"))
    }

    /// As ``connectToNode(_:callbackScheme:)``, for any callback.
    public func connectToNode(_ url: String, callback: CloudCallback) async {
        errorMessage = nil
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard Self.mayCarryCredentials(base) else {
            errorMessage = Self.insecureNodeURLMessage
            return
        }
        storage.nodeURL = base
        let options = AuthLoginOptions(
            callbackUrl: callback.url, mode: config.mode.rawValue, packageName: config.packageName,
            permissions: config.mode.permissions, registryUrl: config.registryURL,
            packageVersion: config.packageVersion)
        let loginURL = Mero.buildAuthLoginUrl(nodeUrl: base, options: options, stateStore: authStateStore)
        guard let login = URL(string: loginURL) else {
            errorMessage = "Enter a valid node URL (e.g. http://localhost:2428)."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let returned = try await webAuthenticator.authenticate(url: login, callback: callback)
            // Handed back by the auth session, never opened as a link: its
            // scheme cannot have been claimed by another app.
            if !(await adoptAuthCallback(returned, allowCustomScheme: true)) {
                errorMessage = "The node's login page did not return a session."
            }
        } catch is WebAuthenticationCancelled {
            // A choice, not an error.
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Adopt an SSO callback (`…#access_token=…&node_url=…`) for a login this
    /// app began. Returns `false` when `url` is not one.
    ///
    /// The callback's `node_url` is trusted only against the node the login
    /// was started with, or ``MeroProviderConfig/allowedNodeURLs``
    /// (``NodeTrust``): a tampered callback's tokens are dropped and any
    /// existing session restored instead. A trusted callback's tokens replace
    /// the stored ones only when ``TokenAdoption`` says it is safe.
    ///
    /// The callback must be an `https` Universal Link unless
    /// ``MeroProviderConfig/allowCustomSchemeCallbacks``: any app can claim a
    /// custom scheme.
    @discardableResult
    public func handleAuthCallback(_ url: URL) async -> Bool {
        await adoptAuthCallback(url, allowCustomScheme: config.allowCustomSchemeCallbacks)
    }

    private func adoptAuthCallback(_ url: URL, allowCustomScheme: Bool) async -> Bool {
        guard
            let callback = Mero.parseAuthCallback(
                url.absoluteString, options: ParseAuthCallbackOptions(allowCustomScheme: allowCustomScheme),
                stateStore: authStateStore)
        else {
            return false
        }
        let initiated = storage.nodeURL
        let tokenNode = storage.tokenNodeURL ?? initiated
        let trust = NodeTrust.resolveTrustedNodeURL(
            candidate: callback.nodeUrl.isEmpty ? nil : callback.nodeUrl, initiated: initiated,
            allowedNodeURLs: config.allowedNodeURLs)
        if trust.rejected {
            // Never let a tampered callback log a signed-in person out.
            if isAuthenticated { return true }
            errorMessage =
                "That sign-in named a node this app did not connect to, so it was ignored and no tokens were kept."
            await finishNodeSession(url: initiated, instance: nil, fromCallback: false)
            return true
        }
        guard let trusted = trust.url else { return true }
        let instance = makeNodeMero(trusted)
        let decision = TokenAdoption.resolve(
            callbackAccessToken: callback.accessToken, callbackRefreshToken: callback.refreshToken,
            callbackNodeURL: trusted, stored: await instance.currentTokenData(), storedNodeURL: tokenNode)
        if let tokens = decision.tokens {
            await instance.setTokenData(tokens)
            storage.tokenNodeURL = trusted
        }
        if !callback.applicationId.isEmpty { setApplicationId(callback.applicationId) }
        if !callback.contextId.isEmpty {
            storage.contextId = callback.contextId
            contextId = callback.contextId
        }
        if !callback.contextIdentity.isEmpty {
            storage.contextIdentity = callback.contextIdentity
            contextIdentity = callback.contextIdentity
        }
        storage.nodeURL = trusted
        await finishNodeSession(url: trusted, instance: instance, fromCallback: true)
        return true
    }

    private func setApplicationId(_ id: String) {
        storage.applicationId = id
        applicationId = id
    }

    /// Validate the session on `url` and publish it.
    private func finishNodeSession(url: String?, instance: Mero?, fromCallback: Bool) async {
        guard let url else { return }
        let client = instance ?? makeNodeMero(url)
        let authed = await Self.checkAuth(client)
        if authed {
            await installNode(client, url: url)
            isAuthenticated = true
            isOnline = true
            startHealth(client)
        } else if fromCallback {
            await installNode(client, url: url)
        }
    }

    private func makeNodeMero(_ url: String) -> Mero {
        if let mero, connection == nil { Task { await mero.close() } }
        let base = URL(string: url) ?? URL(fileURLWithPath: "/")
        let nodeConfig = MeroConfig(baseURL: base, timeout: self.config.timeout, tokenStore: makeTokenStore())
        let made = session.map { Mero(config: nodeConfig, session: $0) } ?? Mero(config: nodeConfig)
        mero = made
        return made
    }

    private func installNode(_ client: Mero, url: String) async {
        mero = client
        delegatedSession = nil
        transport = MeroTransportClient(mero: client)
        let raw = await client.admin
        readAdmin = raw
        admin = NodeAdmin(admin: raw, app: config.app)
        nodeURL = url
        if username.isEmpty { username = URL(string: url)?.host ?? url }
        sessionRevision += 1
    }

    /// Whether the node still accepts the stored session — `/auth/validate`,
    /// which asks for no permission. A token the transport rotated while
    /// validating (an expired access token, renewed by its refresh token) is
    /// judged on the token actually held now; `/auth/refresh` is never called
    /// here, so a single-use refresh token is never raced.
    static func checkAuth(_ client: Mero) async -> Bool {
        await verifyAuth(client) == .valid
    }

    enum AuthCheck: Equatable {
        case valid
        case rejected
        /// The node gave no verdict (unreachable, or `5xx`).
        case unreachable
        case noToken
    }

    /// ``checkAuth(_:)``, telling a node that refused the token from one
    /// that could not be asked.
    static func verifyAuth(_ client: Mero) async -> AuthCheck {
        guard let token = await client.currentTokenData()?.accessToken, !token.isEmpty else { return .noToken }
        let auth = await client.auth
        let first = await auth.validateToken(token)
        if first.valid { return .valid }
        if first.isUnreachable { return .unreachable }
        guard let rotated = await client.currentTokenData()?.accessToken, rotated != token else { return .rejected }
        let second = await auth.validateToken(rotated)
        if second.valid { return .valid }
        return second.isUnreachable ? .unreachable : .rejected
    }

    // MARK: - Health (SSE)

    private func stopHealth() {
        healthTask?.cancel()
        healthTask = nil
    }

    /// Follow the node's event stream for ``isOnline``, and act on what its
    /// failures mean: a dead token family or a token minted without
    /// `context:subscribe` logs out; a `401` asks ``checkAuth(_:)``, which
    /// recovers an expired token through the transport's refresh.
    private func startHealth(_ client: Mero) {
        stopHealth()
        let sse = client.sse
        healthTask = Task { [weak self] in
            let updates = sse.updates()
            sse.connect()
            do {
                for try await update in updates {
                    guard let self else { return }
                    switch update {
                    case .connect:
                        self.isOnline = true
                        self.isOfflineSession = false
                    case .event:
                        break
                    case .error(let error):
                        self.isOnline = false
                        self.recover(from: error, client: client)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isOnline = false
                await self.handleTerminal(error)
            }
        }
    }

    /// A stream that stopped for good: what does its error say about the session?
    private func handleTerminal(_ error: Error) async {
        switch error {
        case MeroError.authRevoked:
            await logout()
        case MeroError.http(let http) where http.status == 403:
            // Minted before the `context:subscribe` grant: a refresh re-issues
            // the same unusable token, so only a fresh login helps. Any other
            // 403 is not about the token, and spends nothing.
            if http.headers["x-auth-error"] == "permission_denied" { await logout() }
        default:
            break
        }
    }

    /// A recoverable stream error: only a `401` is worth acting on.
    private func recover(from error: Error, client: Mero) {
        let status = classifyError(error).status
        guard status == 401 || "\(error)".contains("401"), !recovering else { return }
        recovering = true
        Task { [weak self] in
            let check = await Self.verifyAuth(client)
            guard let self else { return }
            defer { self.recovering = false }
            switch check {
            case .valid:
                client.sse.connect()
            case .unreachable:
                // No verdict: keep the session; the stream retries.
                break
            case .rejected, .noToken:
                if self.mero === client { await self.logout() }
            }
        }
    }

    // MARK: - Context selection

    /// Open `contextId` (and its identity): remembered, and for an account the
    /// client is re-routed to the context's own relay.
    public func selectContext(_ contextId: String?, identity: String? = nil) {
        self.contextId = contextId
        contextIdentity = identity
        storage.contextId = contextId
        storage.contextIdentity = identity
        if let delegatedSession { connectWithAccount(delegatedSession) }
    }

    /// Dismiss the last error (``LoginView`` does, when switching between
    /// Cloud and node sign-in).
    public func clearError() {
        errorMessage = nil
        loginFailure = nil
    }

    // MARK: - Development node login

    /// Why a node URL was refused: plain http to a host that is not local.
    /// (== Kotlin `MeroClient.INSECURE_NODE_URL`.)
    public static let insecureNodeURLMessage =
        "This node is not on https or a local network, so its password and tokens would cross the network "
        + "in the clear. Use an https URL."

    /// https, a local address, or ``TransportSecurity/allowInsecureHTTP``.
    static func mayCarryCredentials(_ url: String) -> Bool {
        TransportSecurity.allowInsecureHTTP || TransportSecurity.isSecureOrLocal(url)
    }

    /// Log in with username/password against `nodeURL` — a development node you
    /// run yourself. Not offered by ``LoginView``'s default; mobile sign-in is Cloud.
    ///
    /// The session is kept as an SSO login's is: the node is remembered in
    /// ``storage`` (``MeroAppStorage/nodeURL`` and ``MeroAppStorage/tokenNodeURL``),
    /// so ``restore()`` brings it back after a relaunch given a persistent
    /// token store, and the node's event stream drives ``isOnline``.
    ///
    /// - Parameter packageName: the application to look up on the node
    ///   (`listApplications`, by package) for ``applicationId``;
    ///   ``MeroProviderConfig/packageName`` when `nil`. With neither, or no
    ///   installed application of that package, ``applicationId`` is left as is.
    public func login(
        nodeURL nodeURLString: String, username: String, password: String, packageName: String? = nil
    ) async {
        errorMessage = nil
        loginFailure = nil

        var base = nodeURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            errorMessage = "Enter a valid node URL (e.g. http://localhost:4001)."
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Username and password are required."
            return
        }
        guard Self.mayCarryCredentials(base) else {
            errorMessage = Self.insecureNodeURLMessage
            return
        }

        isLoading = true
        defer { isLoading = false }

        stopHealth()
        let client = makeNodeMero(base)

        do {
            _ = try await client.authenticate(
                Credentials(username: username, password: password))
        } catch {
            self.isAuthenticated = false
            self.loginFailure = LoginFailureReason(error)
            self.errorMessage = friendlyMessage(error)
            return
        }
        storage.nodeURL = base
        storage.tokenNodeURL = base
        self.username = username
        await installNode(client, url: base)
        isAuthenticated = true
        isOnline = true
        isOfflineSession = false
        startHealth(client)
        if let package = packageName ?? config.packageName, !package.isEmpty {
            await resolveNodeApplication(package: package, client: client)
        }
    }

    /// The installed application of `package`, for ``applicationId``: the one
    /// already remembered if it is still installed, else the latest version.
    private func resolveNodeApplication(package: String, client: Mero) async {
        guard let apps = try? await client.admin.listApplications().apps, mero === client else { return }
        let matching = apps.filter { $0.package == package }
        if let current = applicationId, matching.contains(where: { $0.id == current }) { return }
        let latest = matching.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        if let latest { setApplicationId(latest.id) }
    }

    // MARK: - Calls

    /// Run a sample contract call and publish its result (demo affordance).
    /// Over a Cloud session this reads through the relay (query, falling back
    /// to a warrant); over a node login it is a JSON-RPC call.
    public func runSampleRpc(contextId: String, method: String) async {
        errorMessage = nil
        do {
            if let relay = connection?.relay {
                let value = try await relay.query(contextId: contextId, method: method)
                lastRpcResult = "\(value ?? .null)"
            } else if let mero {
                let value: JSONValue = try await mero.rpc.execute(contextId: contextId, method: method)
                lastRpcResult = "\(value)"
            } else if isSignedInWithoutRelay {
                errorMessage = "No relay serves this account yet. Redeem an invitation to get one."
            }
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Sign out and forget everything: retire the relay session and the
    /// account (its relay map and pinned relay keys with it), or the node login
    /// and its tokens, every remembered id and the invitation attempt ledger.
    /// (== mero-react `logout`.)
    ///
    /// The device key stays, so signing back in is one approval, unless
    /// `forgetDevice` — pass it on a shared or handed-over device, so the next
    /// account is not handed a key already certified to this one
    /// (``CloudSignIn/signOut(forgetDevice:)``).
    public func logout(forgetDevice: Bool = false) async {
        stopHealth()
        delegatedTask?.cancel()
        delegatedTask = nil
        if connection != nil || delegatedSession != nil || forgetDevice {
            await cloud.signOut(forgetDevice: forgetDevice)
        }
        if let mero {
            await mero.logout()
        } else {
            // Clear the token store even when not connected, so tokens never
            // linger after a logout.
            makeTokenStore().clear()
        }
        await transport?.close()
        storage.clearAll()
        InvitationCapture.shared.clearAttempts()
        mero = nil
        connection = nil
        transport = nil
        admin = nil
        readAdmin = nil
        delegatedSession = nil
        account = nil
        relayURL = nil
        isSignedInWithoutRelay = false
        cloudNote = nil
        isAuthenticated = false
        isOnline = true
        isOfflineSession = false
        isLoading = false
        username = ""
        nodeURL = ""
        applicationId = nil
        contextId = nil
        contextIdentity = nil
        lastRpcResult = nil
        errorMessage = nil
        loginFailure = nil
        sessionRevision += 1
    }

    // MARK: - Helpers

    /// Show `message` (or clear it with `nil`) where the login surface shows errors.
    public func reportError(_ message: String?) {
        errorMessage = message
    }

    func friendlyMessage(_ error: Error) -> String {
        errorMessages?(error) ?? Self.defaultMessage(for: error)
    }

    /// The built-in words for `error`, as ``errorMessage`` shows them unless
    /// ``errorMessages`` says otherwise. They name no product or vendor.
    public static func defaultMessage(for error: Error) -> String {
        switch error {
        case MeroError.authRevoked:
            return "Your session was revoked. Please sign in again."
        case MeroError.authenticationFailed:
            return "Login failed — check your credentials and node URL."
        case MeroError.network(let message):
            return "Can't connect to the server: \(message)"
        case MeroError.http(let http) where http.status == 429:
            let wait = LoginFailureReason(error)
            if case .rateLimited(let retryAfter?) = wait, retryAfter > 0 {
                let seconds = Int(retryAfter.rounded(.up))
                return "Too many failed attempts. Try again in \(seconds) second\(seconds == 1 ? "" : "s")."
            }
            return "Too many failed attempts. Try again later."
        case MeroError.http(let http) where http.status == 404 && http.url.contains("/auth/"):
            return "No sign-in found at that address — check the node URL."
        case AccountError.enrolmentDeclined:
            return "This device was not approved. You can try again."
        case AccountError.stateMismatch:
            return "That sign-in did not come from this app. Please try again."
        case AccountError.accountSwitch:
            return "That sign-in is for a different account. Sign out first to switch accounts."
        case AccountError.credentialRejected:
            return "The wallet's answer could not be verified, so nothing was saved. Please try again."
        default:
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    static func shortId(_ id: String) -> String {
        id.count > 12 ? "\(id.prefix(6))…\(id.suffix(4))" : id
    }

    private static func defaultKeyStore() -> AnyValueStore<DeviceKeys> {
        #if canImport(Security)
        return .keychain(account: "cloud-device-keys")
        #else
        return .memory()
        #endif
    }

    private static func defaultSessionStore() -> AnyValueStore<CloudSession> {
        #if canImport(Security)
        return .keychain(account: "cloud-session")
        #else
        return .memory()
        #endif
    }

    private static func defaultPendingEnrolmentStore() -> AnyValueStore<PendingEnrolment> {
        #if canImport(Security)
        return .keychain(account: "cloud-enrol-pending")
        #else
        return .memory()
        #endif
    }
}

/// For platforms with no system auth sheet: always fails.
struct UnavailableWebAuthenticator: WebAuthenticating {
    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        throw AccountError.notSignedIn("no system web authentication on this platform")
    }
}

/// What ``MeroClient/resumeNodeSession()`` found.
public enum NodeSessionRestore: String, Sendable, Equatable {
    /// The node accepted the stored token; the session is live.
    case restored
    /// The node could not be asked; the session runs on the held tokens until
    /// it can (``MeroClient/isOfflineSession``).
    case offline
    /// The node refused the stored token: sign in again.
    case rejected
    /// Nothing to restore: no stored node or no token for it, or a session is
    /// already up.
    case noSession
}
