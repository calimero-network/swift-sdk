import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

/// How a ``MeroAppSession`` treats links. (== Kotlin `MeroAppSessionOptions`.)
public struct MeroAppSessionOptions: Sendable {
    /// Whether a link the system handed the app is one of this app's
    /// invitations. `nil` takes ``MeroAppSession/isInvitationLink(_:packageName:)``:
    /// a link carrying `invitation=…` whose path names the app's package.
    public var isInvitation: (@Sendable (String) -> Bool)?

    public init(isInvitation: (@Sendable (String) -> Bool)? = nil) {
        self.isInvitation = isInvitation
    }
}

/// What an invitation link carries: `base58(deflate(json))` of this, in the
/// `invitation` query parameter of `https://links.calimero.network/<package>/join`.
/// (== Kotlin `InvitationLinkPayload`.)
///
/// ```json
/// {"invitation":{"orgId":"…","token":"inv_…"},"namespaceId":"…","contextId":"…"}
/// ```
///
/// `namespaceId` is the organization (the same as `invitation.orgId`);
/// `contextId` optionally names the app instance to open after joining. An
/// app may add fields of its own (a name to show): decoding ignores them.
public struct InvitationLinkPayload: Codable, Sendable, Equatable {
    public var invitation: OrgInvitation
    public var namespaceId: String
    public var contextId: String?

    public init(invitation: OrgInvitation, namespaceId: String? = nil, contextId: String? = nil) {
        self.invitation = invitation
        self.namespaceId = namespaceId ?? invitation.orgId
        self.contextId = contextId
    }

    /// The shareable link for this payload, for the app with `packageName`.
    public func link(packageName: String) throws -> String {
        InviteLink.invitation(token: try InviteCodec.encode(self), slug: packageName)
    }

    /// The payload a link (or a pasted token) carries, or `nil` when it carries
    /// none or names another app's package.
    public static func from(link: String, packageName: String?) -> InvitationLinkPayload? {
        guard let token = InviteLink.token(fromPasted: link, expectedSlug: packageName) else { return nil }
        return try? InviteCodec.decode(InvitationLinkPayload.self, from: token)
    }
}

/// A Calimero app's signed-in account on a Calimero 1.0 cluster: passkey
/// sign-in (``MeroClient``), and the ``MeroAppBackend`` built over it
/// (``CloudAppBackend``). Keep one for the app's life (a `@StateObject` at
/// the root). (== Kotlin `com.calimero.mero.compose.MeroAppSession`.)
///
/// ```swift
/// @StateObject var session = MeroAppSession(
///     packageName: "com.example.board", callback: .scheme("board"),
///     config: MeroProviderConfig(nodeURL: "https://node.example"))
///
/// .task { await session.restore() }
/// .onOpenURL { url in Task { await session.handle(url) } }
/// ```
///
/// Screens read ``backend`` (and re-read when ``revision`` moves); view
/// models take it as `any MeroAppBackend`, so a test hands them
/// `MeroKitTestSupport`'s `InMemoryAppBackend`. A generated contract client
/// calls `session.contract.bound(to: appId)`.
@MainActor
public final class MeroAppSession: ObservableObject {
    public let client: MeroClient
    /// Where the consent page sends the person back to (its `returnTo`).
    public let callback: CloudCallback
    public let options: MeroAppSessionOptions

    /// The signed-in account's backend, or `nil` when signed out.
    @Published public private(set) var backend: (any MeroAppBackend)?
    /// Bumped whenever ``backend`` is rebuilt, so screens re-read.
    @Published public private(set) var revision = 0
    /// ``restore()`` is running.
    @Published public private(set) var isRestoring = false
    /// An invitation link that arrived (``handle(_:)``) and waits to be
    /// redeemed (``redeemPendingInvitation()``). Clear it with ``dismissPendingInvitation()``.
    @Published public private(set) var pendingInvitation: String?

    private var lastKey = ""
    private var restoreTask: Task<Void, Never>?
    #if canImport(Combine)
    private var watching: AnyCancellable?
    #endif

    /// A session over `client`, whose ``MeroProviderConfig/packageName`` names the app's package.
    public init(client: MeroClient, callback: CloudCallback, options: MeroAppSessionOptions = MeroAppSessionOptions()) {
        self.client = client
        self.callback = callback
        self.options = options
        #if canImport(Combine)
        watching = client.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        #endif
        rebuild()
    }

    #if canImport(Security)
    /// A session with its own ``MeroClient``, its session kept in the
    /// Keychain under `keychainService`.
    ///
    /// - Parameters:
    ///   - packageName: the app's package (`com.example.board`).
    ///   - config: the cluster; its `packageName` is replaced by `packageName`.
    ///   - walletURL: ignored on 1.0 (there is no wallet); kept so apps that pass it build.
    public convenience init(
        packageName: String, callback: CloudCallback, config: MeroProviderConfig = MeroProviderConfig(),
        walletURL: URL? = nil, keychainService: String = "network.calimero.merokit",
        options: MeroAppSessionOptions = MeroAppSessionOptions()
    ) {
        var config = config
        config.packageName = packageName
        let client = MeroClient(config: config, store: KeychainCloudSessionStore(service: keychainService))
        self.init(client: client, callback: callback, options: options)
    }
    #endif

    // MARK: - State

    /// Signed in.
    public var isSignedIn: Bool { client.isAuthenticated }
    /// The account, or `nil`.
    public var account: String? { client.account }
    /// The app's package: what a new org is founded for and an app instance
    /// created from (1.0's word for the application).
    public var applicationId: String? { client.config.packageName }
    /// True once signed in: a node serves every account on 1.0.
    public var hasRelay: Bool { backend?.hasRelay ?? false }
    /// Whether ``MeroAppBackend/events(contextId:)`` streams.
    public var canSubscribe: Bool { backend?.canSubscribe ?? false }
    /// The contract in any app instance: ``NoRelayContextContract`` while signed out.
    public var contract: any ContextContract { backend?.contract ?? NoRelayContextContract() }

    // MARK: - Sign-in

    /// Reconnect the stored session, if there is one. A link that arrives
    /// meanwhile (a cold start) waits for this to finish.
    public func restore() async {
        if let restoreTask { return await restoreTask.value }
        isRestoring = true
        let task = Task { _ = await client.restore() }
        restoreTask = task
        await task.value
        restoreTask = nil
        isRestoring = false
        rebuild()
    }

    /// Sign in with a passkey (the device's; on a development cluster a soft
    /// one kept for the node). A failure lands in the client's `errorMessage`.
    public func signIn() async {
        await client.signIn()
        rebuild()
    }

    /// Create an account named `name` with a new passkey, and sign in.
    public func signUp(name: String) async {
        await client.signUp(name: name)
        rebuild()
    }

    /// Talk to `nodeURL` (a development cluster with `allowMock`) before signing in.
    public func connect(nodeURL: String, allowMock: Bool = false) {
        client.connect(nodeURL: nodeURL, allowMock: allowMock)
        rebuild()
    }

    /// Sign out. `forgetDevice` is ignored on 1.0 (the passkey stays on the
    /// device either way); kept so apps that pass it build.
    public func signOut(forgetDevice: Bool = false) async {
        await client.logout()
        rebuild()
    }

    /// A URL the system handed the app: one of this app's invitation links
    /// (held in ``pendingInvitation`` for the person to confirm) or a consent
    /// page's return. Returns whether it was either.
    @discardableResult
    public func handle(_ url: URL) async -> Bool {
        if let restoreTask { await restoreTask.value }
        if consentReturn(url) != nil { return true }
        let raw = url.absoluteString
        let recognised =
            options.isInvitation?(raw) ?? Self.isInvitationLink(raw, packageName: client.config.packageName)
        guard recognised else { return false }
        pendingInvitation = raw
        return true
    }

    /// Forget ``pendingInvitation``: redeemed, or declined.
    public func dismissPendingInvitation() {
        pendingInvitation = nil
    }

    /// A shareable invitation link to `namespaceId` (an org): an invite token
    /// minted on the node, in ``InvitationLinkPayload``'s shape.
    public func createInvitationLink(namespaceId: String, contextId: String? = nil) async throws -> String {
        guard let backend else { throw AccountError.notSignedIn("sign in to invite") }
        let invitation = try await backend.createInvitation(namespaceId: namespaceId)
        return try InvitationLinkPayload(invitation: invitation, namespaceId: namespaceId, contextId: contextId)
            .link(packageName: client.config.packageName ?? "")
    }

    /// Redeem ``pendingInvitation`` (an ``InvitationLinkPayload`` link):
    /// `POST /invites/{token}/redeem`, then clear it.
    @discardableResult
    public func redeemPendingInvitation() async throws -> AppJoinedNamespace {
        guard let backend else { throw AccountError.notSignedIn("sign in to join") }
        guard let link = pendingInvitation,
            let payload = InvitationLinkPayload.from(link: link, packageName: client.config.packageName)
        else { throw AccountError.invalidInput("no invitation to redeem") }
        let joined = try await backend.joinNamespace(namespaceId: payload.namespaceId, invitation: payload.invitation)
        pendingInvitation = nil
        await didJoinNamespace()
        return joined
    }

    /// After redeeming an invitation: re-read what the account sees.
    public func didJoinNamespace() async {
        revision += 1
    }

    // MARK: - Approvals

    /// What waits for the user's decision in `org` (or their own apps).
    public func pendingApprovals(org: String? = nil) async throws -> PendingApprovals {
        guard let cloud = client.cloud else { throw AccountError.notSignedIn("sign in first") }
        return try await cloud.pendingApprovals(org: org)
    }

    /// Ask the user to approve on the node's consent page, in the system
    /// browser; answers the decision.
    public func requestConsent(_ request: @escaping (_ returnTo: String) -> ConsentRequest) async -> ConsentResult? {
        await client.requestConsent(request, callback: callback)
    }

    /// Rebuild ``backend`` from the client's current session. A no-op when
    /// nothing about the session changed, so open screens are not reset.
    public func rebuild() {
        let key = [
            "\(client.sessionRevision)", client.account ?? "-", client.nodeURL ?? "-",
            client.cloud == nil ? "0" : "1",
        ].joined(separator: "|")
        guard key != lastKey else { return }
        lastKey = key
        if let cloud = client.cloud, let account = client.account {
            backend = CloudAppBackend(
                client: cloud, account: account, packageName: client.config.packageName ?? "",
                packageVersion: client.config.packageVersion)
        } else {
            backend = nil
        }
        revision += 1
    }

    // MARK: - Links

    /// Whether `raw` is an invitation to the app with `packageName`: it
    /// carries `invitation=…`, and its path names the package. Without a
    /// package any invitation link is. (== Kotlin `MeroAppSession.isInvitationLink`.)
    public nonisolated static func isInvitationLink(_ raw: String, packageName: String?) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query = trimmed.firstIndex(of: "?") else { return false }
        let hasToken = trimmed[trimmed.index(after: query)...].split(separator: "&").contains { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && parts[0] == Substring(InviteLink.invitationParam) && !parts[1].isEmpty
        }
        guard hasToken else { return false }
        guard let packageName, !packageName.isEmpty else { return true }
        let path = trimmed[..<query].split(separator: "/").map { $0.lowercased() }
        return path.contains(packageName.lowercased())
    }
}
