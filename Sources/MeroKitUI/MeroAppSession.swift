import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

/// How a ``MeroAppSession`` treats links and where it founds and joins.
/// (== Kotlin `MeroAppSessionOptions`.)
public struct MeroAppSessionOptions: Sendable {
    /// Whether a link the system handed the app is one of this app's
    /// invitations. `nil` takes ``MeroAppSession/isInvitationLink(_:packageName:)``:
    /// a link carrying `invitation=…` whose path names the app's package.
    public var isInvitation: (@Sendable (String) -> Bool)?
    /// What a new namespace is founded with. `nil` resolves the app's package
    /// from the registry. (``DelegatedAppBackend/foundingApplication``.)
    public var foundingApplication: FoundingApplication?
    /// Where to send a join. `nil` asks the Cloud manager for the admitting
    /// relay. (``DelegatedAppBackend/joinNodeURL``.)
    public var joinNodeURL: String?

    public init(
        isInvitation: (@Sendable (String) -> Bool)? = nil, foundingApplication: FoundingApplication? = nil,
        joinNodeURL: String? = nil
    ) {
        self.isInvitation = isInvitation
        self.foundingApplication = foundingApplication
        self.joinNodeURL = joinNodeURL
    }
}

/// A Calimero app's signed-in account, delegated only: Calimero Cloud
/// enrolment (the wallet certifies this device's key), the account's relay
/// from the Cloud manager, and the ``MeroAppBackend`` built over that relay.
/// Keep one for the app's life (a `@StateObject` at the root).
/// (== Kotlin `com.calimero.mero.compose.MeroAppSession`.)
///
/// There is no node login and no node URL: the ``MeroClient`` is only driven
/// through its Cloud entry points (`signInWithCloud`, `restoreCloudSession`,
/// `handleEnrolmentCallback`, `logout`).
///
/// ```swift
/// @StateObject var session = MeroAppSession(
///     packageName: "com.example.board", callback: .https(host: "board.example.com", path: "/enrol"))
///
/// .task { await session.restore() }
/// .onOpenURL { url in Task { await session.handle(url) } }
/// ```
///
/// Screens read ``backend`` (and re-read when ``revision`` moves); view
/// models take it as `any MeroAppBackend`, so a test hands them
/// `MeroKitTestSupport`'s `InMemoryAppBackend`. A generated contract client
/// calls `session.contract.bound(to: contextId)`.
@MainActor
public final class MeroAppSession: ObservableObject {
    public let client: MeroClient
    /// Where the wallet sends the person back to.
    public let callback: CloudCallback
    public let options: MeroAppSessionOptions

    /// The signed-in account's backend, or `nil` when signed out.
    @Published public private(set) var backend: (any MeroAppBackend)?
    /// Bumped whenever ``backend`` is rebuilt, so screens re-read. Not bumped
    /// when nothing about the session changed, so open screens are not reset.
    @Published public private(set) var revision = 0
    /// ``restore()`` is running.
    @Published public private(set) var isRestoring = false
    /// An invitation link that arrived (``handle(_:)``) and waits to be
    /// redeemed. Clear it with ``dismissPendingInvitation()``.
    @Published public private(set) var pendingInvitation: String?

    private var lastKey = ""
    private var restoreTask: Task<Void, Never>?
    #if canImport(Combine)
    private var watching: AnyCancellable?
    #endif

    /// A session over `client`, whose ``MeroProviderConfig/packageName`` names
    /// the app's registry package.
    public init(client: MeroClient, callback: CloudCallback, options: MeroAppSessionOptions = MeroAppSessionOptions()) {
        self.client = client
        self.callback = callback
        self.options = options
        #if canImport(Combine)
        // The client learns things after a call returns (the application id,
        // a relay key): rebuild then too. `@Published` fires before the
        // value is set, so the rebuild runs on the next turn.
        watching = client.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        #endif
        rebuild()
    }

    #if canImport(Security)
    /// A session with its own ``MeroClient``: device keys, session and
    /// tokens in the Keychain under `keychainService`.
    ///
    /// - Parameters:
    ///   - packageName: the app's registry package (`com.example.board`):
    ///     what namespaces are founded with and invitation links carry.
    ///   - config: the registry and Cloud manager; its `packageName` is
    ///     replaced by `packageName`.
    ///   - walletURL: the wallet's enrolment page, when not the default.
    public convenience init(
        packageName: String, callback: CloudCallback, config: MeroProviderConfig = MeroProviderConfig(),
        walletURL: URL? = nil, keychainService: String = "network.calimero.merokit",
        options: MeroAppSessionOptions = MeroAppSessionOptions()
    ) {
        var config = config
        config.packageName = packageName
        var cloud = CloudConfig(cloudBaseURL: config.cloudBaseURL ?? CloudClient.defaultBaseURL)
        if let walletURL { cloud.walletURL = walletURL }
        let client = MeroClient(
            cloud: CloudSignIn.keychain(config: cloud, service: keychainService), config: config)
        self.init(client: client, callback: callback, options: options)
    }
    #endif

    // MARK: - State

    /// Signed in with a Calimero account.
    public var isSignedIn: Bool { client.isAuthenticated && client.isDelegated }
    /// The account, 64 hex, or `nil`.
    public var account: String? { client.account }
    /// The app's application id, once resolved from its package.
    public var applicationId: String? { client.applicationId }
    /// Whether a relay serves the account. Without one only joining works.
    public var hasRelay: Bool { backend?.hasRelay ?? false }
    /// Whether ``MeroAppBackend/events(contextId:)`` streams; when not, poll.
    public var canSubscribe: Bool { backend?.canSubscribe ?? false }
    /// The contract in any context: ``NoRelayContextContract`` while signed
    /// out or relayless. `contract.bound(to: contextId)` for a generated client.
    public var contract: any ContextContract { backend?.contract ?? NoRelayContextContract() }

    // MARK: - Sign-in

    /// Reconnect the stored Cloud session, if there is one. The Cloud manager
    /// is asked again which relay serves the account: a relayless session may
    /// have earned one by joining elsewhere. A wallet callback that arrives
    /// meanwhile (a cold start from the wallet) waits for this to finish.
    public func restore() async {
        if let restoreTask { return await restoreTask.value }
        isRestoring = true
        let task = Task { _ = await client.restoreCloudSession() }
        restoreTask = task
        await task.value
        restoreTask = nil
        isRestoring = false
        rebuild()
    }

    /// Open the wallet to approve this device; returns once it is approved,
    /// declined or dismissed. A failure lands in the client's `errorMessage`.
    public func signIn() async {
        await client.signInWithCloud(callback: callback)
        rebuild()
    }

    /// Sign out. The device key stays (the next sign-in reuses it) unless
    /// `forgetDevice`.
    public func signOut(forgetDevice: Bool = false) async {
        await client.logout(forgetDevice: forgetDevice)
        rebuild()
    }

    /// A URL the system handed the app: a wallet callback that finishes a
    /// sign-in, or one of this app's invitation links (held in
    /// ``pendingInvitation`` for the person to confirm). Returns whether it
    /// was either.
    @discardableResult
    public func handle(_ url: URL) async -> Bool {
        if let restoreTask { await restoreTask.value }
        if await client.handleEnrolmentCallback(url) {
            rebuild()
            return true
        }
        let raw = url.absoluteString
        let recognised =
            options.isInvitation?(raw)
            ?? Self.isInvitationLink(raw, packageName: client.config.packageName)
        guard recognised else { return false }
        pendingInvitation = raw
        return true
    }

    /// Forget ``pendingInvitation``: redeemed, or declined.
    public func dismissPendingInvitation() {
        pendingInvitation = nil
    }

    /// After redeeming an invitation (``MeroAppBackend/joinNamespace(namespaceId:invitation:)``):
    /// a session that had no relay now has the admitting one, so reconnect to it.
    public func didJoinNamespace() async {
        guard backend?.hasRelay != true else { return }
        _ = await client.restoreCloudSession()
        rebuild()
    }

    /// Rebuild ``backend`` from the client's current session. A no-op when
    /// nothing about the session changed, so open screens are not reset. Runs
    /// after every call here and whenever the client changes; call it after
    /// driving the client directly.
    public func rebuild() {
        let connection = client.isAuthenticated && client.isDelegated ? client.connection : nil
        let key = [
            "\(client.sessionRevision)", connection?.session.account ?? "-", connection?.session.relayUrl ?? "-",
            connection?.mero == nil ? "0" : "1", client.admin == nil ? "0" : "1", client.applicationId ?? "-",
        ].joined(separator: "|")
        guard key != lastKey else { return }
        lastKey = key
        if let connection, let admin = client.admin {
            backend = DelegatedAppBackend(
                connection: connection, admin: admin, signIn: client.cloudSignIn,
                packageName: client.config.packageName ?? "",
                registryURL: client.config.registryURL ?? ApplicationRegistry.defaultURL,
                applicationId: client.applicationId, foundingApplication: options.foundingApplication,
                joinNodeURL: options.joinNodeURL)
        } else {
            backend = nil
        }
        revision += 1
    }

    // MARK: - Links

    /// Whether `raw` is an invitation to the app with `packageName`: it
    /// carries `invitation=…`, and its path names the package (another app's
    /// invitation decodes just as well, and redeeming it would join that
    /// app's namespace). Without a package any invitation link is.
    /// (== Kotlin `MeroAppSession.isInvitationLink`.)
    public nonisolated static func isInvitationLink(_ raw: String, packageName: String?) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = trimmed.firstIndex(of: "?") else { return false }
        let params = invitationFormQuery(String(trimmed[trimmed.index(after: query)...]))
        guard let token = params[invitationParam], !token.isEmpty else { return false }
        guard let packageName, !packageName.isEmpty else { return true }
        let path = trimmed[..<query].split(separator: "/").map { $0.lowercased() }
        return path.contains(packageName.lowercased())
    }
}
