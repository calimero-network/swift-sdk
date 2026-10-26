import Foundation

// Redeeming an invitation: joining once, and knowing whether it worked. Port
// of mero-js `src/admin-api/redeem-invitation.ts`.
//
// "Did we join?" is not "did the join request resolve?". A namespace join
// whose members are all offline waits for one to appear — longer than a proxy
// or a client keeps a request open — so the request fails and the join lands
// anyway. Membership is the question, with two independent proofs: the request
// resolving, and the namespace being listed. Either one is enough.

/// Why a join failed, as far as it tells a person what to do next.
/// Raw values are mero-js's `InviteFailureReason` strings.
public enum InviteFailureReason: String, Sendable, Equatable, CaseIterable {
    /// The invitation's time ran out. Only a new link helps.
    case expired
    /// The link is malformed or names nothing joinable. Only a new link helps.
    case invalid
    /// The node refused this person (removed, blocked, not allowed).
    case refused
    /// This client's session with the node lapsed; signing in finishes it.
    case signedOut = "signed-out"
    /// No member was reachable to let them in yet. Trying later can work.
    case noOneOnline = "no-one-online"
    /// This client could not reach its own node at all.
    case nodeUnreachable = "node-unreachable"
    /// Nothing more specific is known; the node's message is all there is.
    case unknown
}

/// What a redeem came to, in the terms a UI needs. (== mero-js `RedeemOutcome`.)
///
/// `alreadyMember` is a success, and a distinct one: it is what following a
/// link twice — or a join that landed after its request timed out — looks like.
public enum RedeemOutcome: Sendable, Equatable {
    case joined(namespaceId: String, teamName: String?)
    case alreadyMember(namespaceId: String, teamName: String?)
    /// `message` is the node's own words; `retryable` whether trying again
    /// later could plausibly work (see ``shouldRetain``).
    case failed(namespaceId: String?, message: String, reason: InviteFailureReason, retryable: Bool)

    /// Whether the invitation is finished with: joined, already a member, or
    /// failed for good. (== mero-js `isSettled`.)
    public var isSettled: Bool {
        if case .failed(_, _, _, let retryable) = self { return !retryable }
        return true
    }

    /// Whether to keep the invitation for another attempt later — the inverse
    /// of ``isSettled``, named for the decision it drives. (== mero-js `shouldRetain`.)
    public var shouldRetain: Bool { !isSettled }
}

/// Whether `outcome` means the invitation is finished with. (== mero-js `isSettled`.)
public func isSettled(_ outcome: RedeemOutcome) -> Bool { outcome.isSettled }

/// Whether the invitation should be kept for another attempt. (== mero-js `shouldRetain`.)
public func shouldRetain(_ outcome: RedeemOutcome) -> Bool { outcome.shouldRetain }

/// The two calls a redeem needs, so any client (or any app's join) can drive
/// it. (== mero-js `InviteRedeemer`.)
public struct InviteRedeemer: Sendable {
    /// Send the join; return on success, throw on failure. It need not be
    /// reliable: ``memberships`` settles any ambiguity a throw leaves.
    public var join: @Sendable (String, SignedGroupOpenInvitation) async throws -> Void
    /// Namespace ids this client is a member of. Throwing is "could not
    /// tell", and never turns a join that succeeded into a failure.
    public var memberships: @Sendable () async throws -> [String]

    public init(
        join: @escaping @Sendable (String, SignedGroupOpenInvitation) async throws -> Void,
        memberships: @escaping @Sendable () async throws -> [String]
    ) {
        self.join = join
        self.memberships = memberships
    }
}

/// An invitation to redeem: the namespace it admits to, the invitation, and
/// the team name to echo back on success.
public struct RedeemRequest: Sendable {
    public var namespaceId: String
    public var invitation: SignedGroupOpenInvitation
    public var teamName: String?

    public init(namespaceId: String, invitation: SignedGroupOpenInvitation, teamName: String? = nil) {
        self.namespaceId = namespaceId
        self.invitation = invitation
        self.teamName = teamName
    }
}

/// Join the namespace an invitation names, and report what happened.
/// (== mero-js `redeemInvitation`.)
///
/// Sends the join once and never retries it: a failed request whose namespace
/// is then listed is ``RedeemOutcome/alreadyMember(namespaceId:teamName:)``.
/// Never throws: every caller branches on "already a member" anyway. Most
/// callers want ``AdminSurface/redeemInvitation(_:invitation:groupName:teamName:)``;
/// this form is for a join that is more than one call.
public func redeemInvitation(_ request: RedeemRequest, redeemer: InviteRedeemer) async -> RedeemOutcome {
    // The id comes from the invite, so it is untrusted: refuse anything but a
    // namespace id before it is put in a path. (SEC-02)
    guard isNamespaceId(request.namespaceId) else {
        return .failed(
            namespaceId: nil, message: "This invitation does not name a valid namespace.", reason: .invalid,
            retryable: false)
    }
    var joinError: Error?
    do {
        try await redeemer.join(request.namespaceId, request.invitation)
    } catch {
        joinError = error
    }
    // The request resolving is proof on its own, so this must not be able to
    // demote a real join: a `memberships()` that throws is "could not tell".
    let listed = try? await redeemer.memberships().contains(request.namespaceId)

    guard let joinError else { return .joined(namespaceId: request.namespaceId, teamName: request.teamName) }
    if listed == true {
        return .alreadyMember(namespaceId: request.namespaceId, teamName: request.teamName)
    }
    let classified = classifyError(joinError)
    var message = classified.message
    if message.trimmingCharacters(in: .whitespaces).isEmpty { message = "Could not join. Check the invitation." }
    let (reason, retryable) = InviteFailures.classify(classified, message: message)
    return .failed(namespaceId: request.namespaceId, message: message, reason: reason, retryable: retryable)
}

/// Whether `id` is a namespace id as core spells it: 64 lowercase hex characters.
func isNamespaceId(_ id: String) -> Bool {
    id.utf8.count == 64 && id.utf8.allSatisfy { Hex.isLowerHexDigit($0) }
}

extension AdminSurface {
    /// Join `namespaceId` with `invitation` and report what happened, with
    /// ``listNamespaces()`` settling a join whose request failed.
    /// `groupName` is sent with the join; `teamName` is echoed back on
    /// success for the caller's UI. (== mero-js `AdminApiClient.redeemInvitation`.)
    public func redeemInvitation(
        _ namespaceId: String, invitation: SignedGroupOpenInvitation, groupName: String? = nil,
        teamName: String? = nil
    ) async -> RedeemOutcome {
        let redeemer = InviteRedeemer(
            join: { namespaceId, invitation in
                _ = try await self.joinNamespace(
                    namespaceId, request: JoinNamespaceRequest(invitation: invitation, groupName: groupName))
            },
            memberships: { try await self.listNamespaces().map(\.namespaceId) })
        return await MeroKit.redeemInvitation(
            RedeemRequest(namespaceId: namespaceId, invitation: invitation, teamName: teamName), redeemer: redeemer)
    }
}

/// How a failed join reads to a person.
enum InviteFailures {
    /// Why a join failed, and whether a later attempt could work. The status
    /// decides where there is one: a 4xx the node chose is final, a 5xx or no
    /// answer is about the moment. A 401 is the client's session, not the
    /// invitation, and a 404 is not specific enough to throw a link away on.
    static func classify(_ error: ClassifiedError, message: String) -> (InviteFailureReason, Bool) {
        let fromText = reasonFromMessage(message)
        if let decided = byStatus(error.status, fromText: fromText) { return decided }
        switch error.kind {
        case .unavailable: return (.noOneOnline, true)
        case .unreachable: return (.nodeUnreachable, true)
        default: break
        }
        // A 500 from a node older than rc.56 may still be a refusal in disguise.
        if let fromText { return (fromText, false) }
        return (.unknown, true)
    }

    private static func byStatus(_ status: Int?, fromText: InviteFailureReason?) -> (InviteFailureReason, Bool)? {
        switch status {
        case 401: return (.signedOut, true)
        case 400: return (fromText ?? .invalid, false)
        case 410: return (.expired, false)
        case 403: return (.refused, false)
        // An expired invitation, a spent one, a removed member: every 409 a
        // join can answer is final.
        case 409: return (fromText ?? .refused, false)
        default: return nil
        }
    }

    /// The reason the message alone names, for a node that answers without a
    /// useful status (older than rc.56, where every refusal was a bare 500).
    /// Kept narrow: anything not recognised here stays retryable.
    static func reasonFromMessage(_ message: String) -> InviteFailureReason? {
        let text = message.lowercased()
        let expired = ["invitation has expired", "invitation expired"]
        // Core rc.56+ names the group between the words.
        let namesExpiry = expired.contains { text.contains($0) }
        if namesExpiry || matches(text, #"\binvitation for group .+? expired at \d+"#) { return .expired }
        let invalid = ["malformed", "does not match namespace_id", "invalid invitation"]
        let namesInvalid = invalid.contains { text.contains($0) }
        if namesInvalid || matches(text, #"\binvitation for group .+? is invalid:"#) { return .invalid }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
