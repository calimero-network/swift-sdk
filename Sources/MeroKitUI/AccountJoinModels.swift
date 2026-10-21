import Foundation
import MeroKit

// Joining from an invitation, whatever the connection, and the account's own
// way in. Port of mero-react `join/useJoinInvitation.ts`,
// `delegated/useDelegatedBootstrap.ts` and `delegated/useAccountEnrolment.ts`.

/// Whether a node's join failure means the invitation itself will never work.
/// Errs toward `false`: a dropped invitation is unrecoverable, a retried one
/// costs a round trip. Phrases, not bare words — "invalid" alone is a proxy's
/// word too. (== mero-react `isFinalInvitationError`.)
public func isFinalInvitationError(_ message: String?) -> Bool {
    guard let message, !message.isEmpty else { return false }
    let text = message.lowercased()
    let finalPhrases = [
        "invitation expired", "expired invitation", "invalid invitation", "invitation is invalid",
        "malformed invitation", "malformed payload", "invalid signature", "signature verification failed",
        "not admin", "revoked", "already a member",
    ]
    return finalPhrases.contains { text.contains($0) }
}

/// Whether `url` is the wallet sending the person back — a completed
/// enrolment or a declined one — without consuming it.
/// (== mero-react `isReturningFromWallet`.)
public func isReturningFromWallet(_ url: URL?) -> Bool {
    guard let fragment = url?.fragment, !fragment.isEmpty else { return false }
    let params = invitationFormQuery(fragment)
    if let error = params["error"], !error.isEmpty { return true }
    return ["credential", "account", "device"].allSatisfy { !(params[$0] ?? "").isEmpty }
}

// MARK: - Delegated bootstrap

/// The other door into an account connection: from an invitation rather than
/// the account's relays. A first-time account is served by nothing, so the
/// cloud names no relay for it; this resolves one from the *namespace*,
/// presents the signed join, and connects through the node that took it.
/// (== mero-react `useDelegatedBootstrap`.)
@MainActor
public final class DelegatedBootstrap: ObservableObject {
    @Published public private(set) var isRunning = false
    /// The last attempt's outcome, so a UI can name the failing step.
    @Published public private(set) var result: BootstrapResult?

    private weak var client: MeroClient?

    public init(client: MeroClient) {
        self.client = client
    }

    /// The enrolled account to admit: the session's, else the Cloud sign-in's.
    public func credential() async -> DelegatedSession? {
        if let session = client?.delegatedSession { return session }
        return await client?.cloudSignIn.delegatedSession()
    }

    /// Signed in with nowhere to write: an invitation is what changes that.
    public func needsBootstrap() async -> Bool {
        guard let session = await credential() else { return false }
        return session.relayUrl == nil
    }

    /// Admit this account to the invitation's namespace and connect through the
    /// admitting node. Never throws: every refusal names its ``BootstrapStep``.
    /// - Parameters:
    ///   - nodeURL: a node to present the join to, skipping the cloud lookup.
    ///   - contextId: the context the invitation is for, so its relay is known
    ///     before any listing.
    @discardableResult
    public func bootstrap(
        namespaceId: String, invitation: SignedGroupOpenInvitation, nodeURL: String? = nil, contextId: String? = nil
    ) async -> BootstrapResult {
        guard let client, let held = await credential() else {
            let failure = BootstrapResult.failed(
                BootstrapFailure(
                    step: .noCredential,
                    reason: "This device holds no enrolled account, so there is no identity to admit. Sign in with "
                        + "your account first — the invitation is then what gives it its first membership."))
            result = failure
            return failure
        }
        isRunning = true
        defer { isRunning = false }
        let env = client.delegatedEnvironment
        let outcome = await Self.join(
            client: client, held: held, namespaceId: namespaceId, invitation: invitation, nodeURL: nodeURL, env: env)
        result = outcome
        // Connected only on a node that actually took the join: a session after
        // a refusal would look connected and refuse every write.
        if case .joined(let joined) = outcome {
            env.store.rememberRelay(
                account: held.account, relayURL: joined.relayUrl, namespaceId: namespaceId, contextId: contextId)
            let moved = DelegatedAccounts.carryExecutorAccount(
                from: client.delegatedSession, to: held.on(relay: joined.relayUrl))
            client.connectWithAccount(moved)
        }
        return outcome
    }

    /// Through the Cloud sign-in when it holds this account (it persists the
    /// relay a relayless session gains), else straight from the session.
    private static func join(
        client: MeroClient, held: DelegatedSession, namespaceId: String, invitation: SignedGroupOpenInvitation,
        nodeURL: String?, env: DelegatedEnvironment
    ) async -> BootstrapResult {
        let cloud = client.cloudSignIn
        if let stored = await cloud.restoreSession(), stored.account == held.account {
            do {
                let joined = try await cloud.join(namespaceId: namespaceId, invitation: invitation, nodeURL: nodeURL)
                return .joined(joined.outcome)
            } catch let failure as BootstrapFailure {
                return .failed(failure)
            } catch {
                return .failed(BootstrapFailure(step: .admit, reason: "\(error)"))
            }
        }
        let routing = CloudClient(
            baseURL: client.config.cloudBaseURL ?? env.cloudBaseURL,
            routingCredential: RoutingCredential(credential: held.credential, deviceSecret: held.keys.signSecret),
            session: env.urlSession, timeout: env.timeout)
        return await AccountJoin.bootstrapFromInvitation(
            namespaceId: namespaceId, invitation: invitation, account: held.account, credential: held.credential,
            keys: held.keys, nonce: env.nonces.next(relay: "join:\(held.account)"), nodeURL: nodeURL, cloud: routing,
            session: env.urlSession)
    }
}

// MARK: - Join invitation

/// Which step of ``JoinInvitation/join(_:)`` failed.
public enum JoinInvitationStep: Sendable, Equatable {
    /// An account's bootstrap step.
    case bootstrap(BootstrapStep)
    /// A node's own join (`joinNamespace`, then `joinContext`).
    case nodeJoin

    /// mero-react's step string.
    public var rawValue: String {
        switch self {
        case .bootstrap(let step): return step.rawValue
        case .nodeJoin: return "node-join"
        }
    }
}

/// An invitation to join: the namespace, the context it was for (a workspace
/// invitation names none), and the signed invitation.
/// (== mero-react `JoinInvitationInput`.)
public struct JoinInvitationInput: Sendable {
    public var namespaceId: String
    public var contextId: String?
    public var invitation: SignedGroupOpenInvitation

    public init(namespaceId: String, contextId: String? = nil, invitation: SignedGroupOpenInvitation) {
        self.namespaceId = namespaceId
        self.contextId = contextId
        self.invitation = invitation
    }
}

/// What a join came to, the same shape on either connection.
/// (== mero-react `JoinInvitationResult`.)
public enum JoinInvitationResult: Sendable, Equatable {
    case ok
    /// `isFinal`: no retry can succeed, only a fresh invitation.
    case failed(step: JoinInvitationStep, reason: String, isFinal: Bool, status: Int?)

    public var isOK: Bool { self == .ok }
}

/// Join a namespace (and its context) from an invitation — the same call
/// whatever the connection. (== mero-react `useJoinInvitation`.)
///
/// - A node login joins on its node: `joinNamespace`, then `joinContext`.
/// - An account (no node) signs the join and hands it to an admitter the
///   invitation names (``DelegatedBootstrap``), then writes through that relay.
@MainActor
public final class JoinInvitation: ObservableObject {
    @Published public private(set) var isJoining = false

    private weak var client: MeroClient?
    /// The account path's bootstrap, for its last result.
    public let bootstrap: DelegatedBootstrap

    public init(client: MeroClient) {
        self.client = client
        self.bootstrap = DelegatedBootstrap(client: client)
    }

    /// Join as an account when the connection is one, or when an account is
    /// enrolled and no node session exists.
    private func joinsAsAccount() async -> Bool {
        guard let client else { return false }
        if client.isDelegated { return true }
        guard client.node == nil else { return false }
        return await bootstrap.credential() != nil
    }

    public func join(_ input: JoinInvitationInput) async -> JoinInvitationResult {
        isJoining = true
        defer { isJoining = false }
        if await joinsAsAccount() {
            let outcome = await bootstrap.bootstrap(
                namespaceId: input.namespaceId, invitation: input.invitation, contextId: input.contextId)
            guard case .failed(let failure) = outcome else { return .ok }
            return .failed(
                step: .bootstrap(failure.step), reason: "\(Self.label(failure.step)). \(failure.reason)",
                isFinal: Self.isFinal(failure), status: failure.status)
        }
        guard let node = client?.node else {
            return .failed(step: .nodeJoin, reason: "Not connected to a node.", isFinal: false, status: nil)
        }
        do {
            // The admin directly, not a join action: those resolve `nil` on a
            // failure, which would report a refused join as joined.
            let admin = await node.admin
            _ = try await admin.joinNamespace(
                input.namespaceId, request: JoinNamespaceRequest(invitation: input.invitation))
            if let contextId = input.contextId { _ = try await admin.joinContext(contextId) }
            return .ok
        } catch {
            let classified = classifyError(error)
            let reason = (error as? LocalizedError)?.errorDescription ?? classified.message
            return .failed(
                step: .nodeJoin, reason: reason, isFinal: isFinalInvitationError(reason), status: classified.status)
        }
    }

    /// The namespaces this connection is a member of: a node's own, or an
    /// account's across its relays.
    public func memberships() async throws -> [String] {
        guard let client else { return [] }
        if await joinsAsAccount() {
            guard let session = await bootstrap.credential() else { return [] }
            return try await DelegatedAccounts.listDelegatedNamespaces(session, env: client.delegatedEnvironment)
                .map(\.item.namespaceId)
        }
        guard let node = client.node else { return [] }
        return try await node.admin.listNamespaces().map(\.namespaceId)
    }

    /// The `join` / `memberships` pair ``redeemInvitation(_:redeemer:)``
    /// drives, for this connection. `join` throws on a refusal, carrying its
    /// HTTP status for the outcome's reason.
    public func redeemer(for input: JoinInvitationInput) -> InviteRedeemer {
        InviteRedeemer(
            join: { [weak self] _, _ in
                guard let self else { throw NotConnectedError() }
                if case .failed(_, let reason, _, let status) = await self.join(input) {
                    if let status {
                        throw MeroError.http(
                            HTTPError(status: status, statusText: reason, url: "", headers: [:], bodyText: reason))
                    }
                    throw NotConnectedError(reason)
                }
            },
            memberships: { [weak self] in try await self?.memberships() ?? [] })
    }

    /// Which step failed, in words a person can act on.
    static func label(_ step: BootstrapStep) -> String {
        switch step {
        case .noCredential: return "No enrolled account"
        case .admittersLookup: return "Admitters lookup failed"
        case .noNodes: return "No hosted node serves this namespace"
        case .notInvited: return "This invitation names none of the serving nodes"
        case .invitedUnreachable: return "The invited admitter cannot take a join right now"
        case .noRelayURL: return "The invited admitter has no address yet"
        case .sign: return "The join could not be signed"
        case .admit: return "The admitter refused the join"
        }
    }

    /// An admitter's 400/403 judged the op or the invitation; `not-invited`
    /// and `sign` fail the same way next time. Everything else is a wait.
    static func isFinal(_ failure: BootstrapFailure) -> Bool {
        if failure.step == .admit { return failure.status == 400 || failure.status == 403 }
        return failure.step == .notInvited || failure.step == .sign
    }
}

// MARK: - Account enrolment

/// The account sign-in flow, with no UI: the wallet in the system auth sheet,
/// the certificate verified and the account's relay connected. A thin face
/// over ``MeroClient/signInWithCloud(callback:)`` so a custom sign-in screen
/// reads the same fields mero-react's does. (== mero-react `useAccountEnrolment`.)
@MainActor
public final class AccountEnrolment: ObservableObject {
    /// What to tell the person about the last enrolment: an error, or a
    /// connection with nowhere to write yet.
    @Published public private(set) var note: String?
    /// Whether the last URL handed over was the wallet coming back.
    @Published public private(set) var returning = false
    /// The wallet enrolment goes to.
    @Published public private(set) var walletURL: URL = DeviceEnrolment.defaultWalletURL

    private weak var client: MeroClient?
    public let callback: CloudCallback

    public init(client: MeroClient, callback: CloudCallback) {
        self.client = client
        self.callback = callback
        let cloud = client.cloudSignIn
        Task { [weak self] in
            let url = await cloud.config.walletURL
            self?.walletURL = url
        }
    }

    /// Whether ``walletURL`` is an override rather than the hosted wallet.
    public var customWallet: Bool { walletURL != DeviceEnrolment.defaultWalletURL }

    /// Enrol this device at the wallet and connect.
    public func goToWallet() async {
        guard let client else { return }
        await client.signInWithCloud(callback: callback)
        refreshNote()
    }

    /// Finish an enrolment the app received as a URL (`onOpenURL`).
    @discardableResult
    public func handle(_ url: URL) async -> Bool {
        guard let client, isReturningFromWallet(url) else { return false }
        returning = true
        let handled = await client.handleEnrolmentCallback(url)
        refreshNote()
        return handled
    }

    private func refreshNote() {
        note = client?.errorMessage ?? client?.cloudNote
    }
}
