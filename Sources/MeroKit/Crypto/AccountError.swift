import Foundation

/// Errors from the account layer: signing, device enrolment, the Cloud
/// manager, and the hosted relay.
///
/// Kept apart from ``MeroError`` on purpose. `MeroError` describes one node's
/// HTTP surface; these describe a credential that must not be stored, a relay
/// that would not attest, or an intent a relay refused — outcomes a caller has
/// to show rather than retry blindly.
public enum AccountError: Error, Sendable, Equatable {
    /// An input was malformed before anything was signed or sent (wrong hex
    /// width, a label over the node's limit, …). Nothing was spent.
    case invalidInput(String)

    /// A credential that must not be stored: it does not verify, names another
    /// account or device, or certifies a key this app does not hold.
    case credentialRejected(String)

    /// The person declined at the wallet, or the wallet refused the request.
    case enrolmentDeclined(String)

    /// A wallet or cloud callback answers a request this app did not make (its
    /// `state` is not one this app began, or was already spent).
    case stateMismatch

    /// A verified enrolment names `incoming`, but this device is signed in to
    /// `current`. Nothing was stored: sign out first, or confirm the switch
    /// (``CloudSignIn/completeEnrolment(callbackURL:allowAccountSwitch:)``).
    case accountSwitch(current: String, incoming: String)

    /// The relay's node key could not be established. Reads and events need it;
    /// warranted writes do not.
    case relayKeyUnavailable(String)

    /// A relay refused an intent (HTTP 400/403). `retryable` is true when the
    /// refusal was about the nonce: a fresh warrant (a new call) can succeed.
    case intentRefused(reason: String, retryable: Bool, status: Int)

    /// A server answered with something this client cannot use.
    case protocolViolation(String)

    /// The operation needs a signed-in Cloud session (or a relay) that is absent.
    case notSignedIn(String)

    /// The Cloud manager refused to host a namespace the account founded
    /// (`enable-ha`), naming why: `account_not_linked`,
    /// `account_linked_to_several_users`, `ha_request_pending`, `unknown_relay`
    /// or `relay_not_dialable`. The namespace exists either way.
    case haRefused(code: String, status: Int, body: String?)

    /// Nobody a claimant could reach would admit them with this invitation, so
    /// none was minted. `reason` is `not-hosted` or `no-named-node`.
    case invitationNotClaimable(namespaceId: String, reason: String)

    /// The signed-in cloud account cannot write yet, and the message says
    /// what to go and do: it owns no namespace (or several, and none was
    /// named), HA is off, no relay is assigned yet, or none relays.
    case cloudNotReady(String)

    /// The person declined linking an account at the cloud, or the cloud
    /// refused the link request.
    case linkDeclined(String)

    /// An account's admin (``AccountAdmin``) refused a call that needs a node:
    /// upgrades, installs, aliases, a node's own copy of a context. `method`
    /// names it. Nothing was sent. (== mero-js `NotForAccountError`.)
    case notForAccount(method: String)

    /// An account that has joined nothing has no relay, so nothing serves
    /// `method` yet; redeem an invitation first. (== mero-js `NoRelayError`.)
    case noRelay(method: String)
}

/// Why an account's invitation was not minted
/// (``AccountError/invitationNotClaimable(namespaceId:reason:)``).
/// (== mero-js `InvitationNotClaimableError.reason`.)
public enum InvitationNotClaimableReason: String, Sendable, Equatable, CaseIterable {
    /// The cloud lists no node holding the namespace. A relay it does not
    /// list cannot stand in: an address on the invitation is unsigned.
    case notHosted = "not-hosted"
    /// The cloud's nodes are not among the admitters the invitation would name.
    case noNamedNode = "no-named-node"
}

extension AccountError {
    /// The typed reason of an ``invitationNotClaimable(namespaceId:reason:)``, or `nil`.
    public var invitationNotClaimableReason: InvitationNotClaimableReason? {
        guard case .invitationNotClaimable(_, let reason) = self else { return nil }
        return InvitationNotClaimableReason(rawValue: reason)
    }
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return m
        case .credentialRejected(let m): return "Credential rejected: \(m)"
        case .enrolmentDeclined(let m): return m
        case .stateMismatch:
            return "This callback answers a request this app did not make — the state it carries is not one it sent."
        case .accountSwitch(let current, let incoming):
            return "This sign-in is for account \(incoming), but this device is signed in to \(current). "
                + "Sign out first to switch accounts."
        case .relayKeyUnavailable(let m): return "Relay node key unavailable: \(m)"
        case .intentRefused(let reason, _, let status): return "Relay refused the intent (HTTP \(status)): \(reason)"
        case .protocolViolation(let m): return m
        case .notSignedIn(let m): return m
        case .haRefused(let code, _, _): return CloudClient.haRefusalMessages[code] ?? "The cloud refused HA: \(code)"
        case .invitationNotClaimable(let ns, let reason):
            return reason == InvitationNotClaimableReason.notHosted.rawValue
                ? "nobody could claim an invitation to \(ns) yet: the cloud lists no node holding the namespace, so an "
                    + "invitee with no node of their own has no relay to be admitted through."
                : "nobody could claim an invitation to \(ns): the cloud routes to none of the relays or admins it "
                    + "would name as admitters"
        case .cloudNotReady(let m): return m
        case .linkDeclined(let m): return m
        case .notForAccount(let method): return "\(method) is not available for an account: it needs a node"
        case .noRelay(let method):
            return "\(method) needs a relay, and this account has none yet: join from an invitation first"
        }
    }
}
