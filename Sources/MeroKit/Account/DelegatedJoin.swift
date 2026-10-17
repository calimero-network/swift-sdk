import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension DelegatedAccounts {
    /// Redeem an invitation for an account: resolve the relay the invitation
    /// names through the cloud's routing, have it admit the account, record
    /// that relay as the namespace's, and hand the session over to `onJoined`
    /// — moved onto the admitting relay, keeping the executor account when the
    /// relay did not change. (== mero-js `joinAsAccount`.)
    ///
    /// It is what an account's ``AccountAdmin/joinNamespace(_:request:)`` runs
    /// (set it as ``AccountAdminDeps/join``), and it works with no relay yet:
    /// the join is how an account gets its first one. A refused join throws
    /// the ``BootstrapFailure`` (its `step`, `reason` and HTTP `status`);
    /// nothing is remembered or switched then.
    @discardableResult
    public static func joinAsAccount(
        _ session: DelegatedSession, namespaceId: String, invitation: SignedGroupOpenInvitation,
        cloudBaseURL: URL? = nil, env: DelegatedEnvironment = DelegatedEnvironment(),
        onJoined: @Sendable (DelegatedSession) -> Void
    ) async throws -> String {
        let cloud = CloudClient(
            baseURL: cloudBaseURL ?? env.cloudBaseURL,
            routingCredential: RoutingCredential(credential: session.credential, deviceSecret: session.keys.signSecret),
            session: env.urlSession, timeout: env.timeout)
        let outcome = try await AccountJoin.bootstrapFromInvitation(
            namespaceId: namespaceId, invitation: invitation, account: session.account,
            credential: session.credential, keys: session.keys,
            nonce: env.nonces.next(relay: "join:\(session.account)"), cloud: cloud, session: env.urlSession
        ).get()
        env.store.rememberRelay(account: session.account, relayURL: outcome.relayUrl, namespaceId: namespaceId)
        onJoined(carryExecutorAccount(from: session, to: session.on(relay: outcome.relayUrl)))
        return namespaceId
    }
}
