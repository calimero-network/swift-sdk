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

    /// The enrolment answers a request this app did not make (`state` mismatch).
    case stateMismatch

    /// The relay's node key could not be established. Reads and events need it;
    /// warranted writes do not.
    case relayKeyUnavailable(String)

    /// A relay refused an intent (HTTP 400/403). `retryable` is true when the
    /// refusal was about the nonce, which recovery can fix.
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
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return m
        case .credentialRejected(let m): return "Credential rejected: \(m)"
        case .enrolmentDeclined(let m): return m
        case .stateMismatch:
            return "This enrolment answers a request this app did not make — the state it carries is not the one sent."
        case .relayKeyUnavailable(let m): return "Relay node key unavailable: \(m)"
        case .intentRefused(let reason, _, let status): return "Relay refused the intent (HTTP \(status)): \(reason)"
        case .protocolViolation(let m): return m
        case .notSignedIn(let m): return m
        case .haRefused(let code, _, _): return CloudClient.haRefusalMessages[code] ?? "The cloud refused HA: \(code)"
        case .invitationNotClaimable(let ns, let reason):
            return reason == "not-hosted"
                ? "Nobody could claim an invitation to \(ns) yet: the namespace is not hosted in the cloud and has no "
                    + "relay in it. Link this account to your cloud user in the wallet and enable HA, then invite."
                : "Nobody could claim an invitation to \(ns): the cloud routes to none of the relays or admins it "
                    + "would name as admitters."
        }
    }
}
