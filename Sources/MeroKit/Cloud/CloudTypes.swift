import Foundation

// The shapes the Calimero Cloud manager's signed-in routes answer with.
// Port of the types in mero-js `src/cloud/cloud-client.ts`.

/// Who a cloud login belongs to.
public struct CloudUser: Codable, Sendable, Equatable {
    public var email: String
    public var name: String?
    public var picture: String?

    public init(email: String, name: String? = nil, picture: String? = nil) {
        self.email = email
        self.name = name
        self.picture = picture
    }
}

/// A Calimero Cloud (MDMA) login session: who is signed in, and until when.
/// (== mero-js `CloudSession`; named apart from ``CloudSession``, which is a
/// device-enrolled account.)
public struct CloudLoginSession: Codable, Sendable, Equatable {
    /// The bearer token every signed-in cloud route takes.
    public var sessionToken: String
    /// Epoch **seconds**, as MDMA reports it. `0` means "unknown" — a token
    /// handed in without its expiry — never "expired": the server judges.
    public var expiresAt: Int64
    public var user: CloudUser

    public init(sessionToken: String, expiresAt: Int64, user: CloudUser) {
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.user = user
    }
}

/// One namespace the signed-in user owns.
public struct CloudNamespace: Sendable, Equatable {
    public let namespaceId: String
    /// Always equal to `namespaceId`; MDMA keeps it for wire compatibility.
    public let groupId: String
    /// `enabled`, `disabled` or `none` (HA was never enabled).
    public let haStatus: String
    public let haEnabledAt: String?
    public let contexts: [String]
    /// The cloud's `fleet_replicas`, as sent (`{current, limit}` today).
    public let fleetReplicas: JSONValue?

    public init(
        namespaceId: String, groupId: String, haStatus: String, haEnabledAt: String? = nil, contexts: [String] = [],
        fleetReplicas: JSONValue? = nil
    ) {
        self.namespaceId = namespaceId
        self.groupId = groupId
        self.haStatus = haStatus
        self.haEnabledAt = haEnabledAt
        self.contexts = contexts
        self.fleetReplicas = fleetReplicas
    }
}

/// One admitter's refusal of a relay's join, in its own words.
public struct CloudRelayRefusal: Sendable, Equatable {
    /// The admitter's libp2p peer id.
    public let peer: String
    /// Text to show a person, never to parse.
    public let reason: String

    public init(peer: String, reason: String) {
        self.peer = peer
        self.reason = reason
    }
}

/// A fleet node's own account of its latest attempt to join a namespace.
public struct CloudRelayJoin: Sendable, Equatable {
    /// `admitted`, `refused`, `waiting` or `error`, passed through as sent.
    public let state: String
    /// Consecutive attempts without admission.
    public let attempts: Int
    public let refusals: [CloudRelayRefusal]
    /// Why the attempt itself failed, when `state` is `error`.
    public let error: String?
    /// ISO 8601 (UTC, no offset).
    public let reportedAt: String?

    public init(state: String, attempts: Int, refusals: [CloudRelayRefusal], error: String?, reportedAt: String?) {
        self.state = state
        self.attempts = attempts
        self.refusals = refusals
        self.error = error
        self.reportedAt = reportedAt
    }
}

/// One attested node the cloud assigned to a namespace, described as a relay.
///
/// Filter on ``canExecute`` before signing a warrant for it: it is the cloud's
/// own verdict (a `RelayTee` relays by role, a `ReadOnlyTee` never does; only a
/// node reporting no role is decided by the `CAN_AUTHOR_ON_BEHALF` grant).
public struct CloudRelay: Sendable, Equatable {
    public let peerId: String
    /// Base URL to present intents to, or `nil` when the cloud knows none yet.
    public let relayUrl: String?
    /// The account a warrant for this relay must name as its executor, hex.
    public let executorAccount: String?
    /// The relay node's Ed25519 signing key, when the cloud publishes it
    /// (`node_key` or `node_public_key`; not yet sent — mdma #312). Never the
    /// `peerId`, which is a different key.
    public let nodeKey: String?
    /// `assigned` or `active`.
    public let status: String
    /// Whether the relay holds `CAN_AUTHOR_ON_BEHALF` on the namespace.
    public let authorshipReady: Bool
    /// `RelayTee`, `ReadOnlyTee`, or `nil` for a node too old to report one.
    public let teeRole: String?
    /// Whether an intent can be presented here now.
    public let canExecute: Bool
    public let lastSeenAt: String?
    public let confirmedAt: String?
    /// `confirmed`, `pending`, `refused`, `absent` — or `nil` from an older cloud.
    public let admission: String?
    /// The cloud's one-line explanation of ``admission``.
    public let admissionHint: String?
    /// What the relay reported about its latest attempt to join.
    public let join: CloudRelayJoin?
}

/// One namespace of the caller's that a machine serves.
public struct CloudMachineNamespace: Sendable, Equatable {
    public let namespaceId: String
    public let status: String
    public let authorshipReady: Bool
    public let teeRole: String?
    /// Whether the machine's heartbeat for this namespace is recent.
    public let fresh: Bool
    public let confirmedAt: String?
    public let lastSeenAt: String?
}

/// One attested machine serving this account.
public struct CloudMachine: Sendable, Equatable {
    public let peerId: String
    public let relayUrl: String?
    public let executorAccount: String?
    /// Whether this machine can write for the caller somewhere.
    public let canExecute: Bool
    /// Only the caller's own namespaces, even on a shared machine.
    public let namespaces: [CloudMachineNamespace]
}

/// A Calimero account linked to this cloud login.
public struct CloudLinkedAccount: Sendable, Equatable {
    /// 64 hex.
    public let accountId: String
    public let linkedAt: String?
    /// Whether a recovery envelope is stored for this account.
    public let hasRecoveryEnvelope: Bool
}

/// What ``CloudClient/getMyAccounts()`` reports.
public struct CloudLinkedAccounts: Sendable, Equatable {
    public let accounts: [CloudLinkedAccount]
    /// How many the plan allows; `nil` means no limit.
    public let limit: Int?
}

/// A single-use challenge to sign with an account root to **link** it.
public struct AccountLinkChallenge: Sendable, Equatable {
    /// Sign verbatim — an opaque sealed string.
    public let nonce: String
    /// Epoch milliseconds, or `nil` when the cloud did not say.
    public let expiresAtMs: Int64?
}

/// A link proof assembled by whoever holds the root, for
/// ``CloudClient/submitAccountLink(_:)``.
public struct AccountLinkProof: Sendable, Equatable {
    /// The account being claimed, 64 hex — the one ``rootPublicKey`` names.
    public var accountId: String
    public var rootPublicKey: String
    /// The challenge that was signed.
    public var nonce: String
    /// ``signAccountLink(_:)``'s output, standard base64.
    public var signature: String

    public init(accountId: String, rootPublicKey: String, nonce: String, signature: String) {
        self.accountId = accountId
        self.rootPublicKey = rootPublicKey
        self.nonce = nonce
        self.signature = signature
    }
}

/// A single-use challenge for an account root to **sign in** with (~2 min).
public struct AccountLoginChallenge: Sendable, Equatable {
    public let nonce: String
    /// Epoch milliseconds.
    public let expiresAtMs: Int64
}

/// A login proof assembled by whoever holds the root, for
/// ``CloudClient/submitAccountLogin(_:)``. No account id: the cloud derives it
/// from the key.
public struct AccountLoginProof: Sendable, Equatable {
    public var rootPublicKey: String
    public var nonce: String
    /// ``signAccountLogin(_:)``'s output, standard base64.
    public var signature: String

    public init(rootPublicKey: String, nonce: String, signature: String) {
        self.rootPublicKey = rootPublicKey
        self.nonce = nonce
        self.signature = signature
    }
}

/// The outcome of linking an account to a cloud login.
public struct CloudAccountLink: Sendable, Equatable {
    public let accountId: String
    public let linkedAt: String?
    /// True when this account was already linked to this same login (a 200
    /// no-op, not an error).
    public let alreadyLinked: Bool
}

/// Where to send someone so a cloud login can consent to linking an account.
public struct AccountLinkHandoff: Sendable, Equatable {
    /// The portal URL to open in the system auth sheet.
    public let url: URL
    /// The account the consent is for, to show the person.
    public let accountId: String
}

/// What the portal answered on the callback: a grant, a refusal, or neither
/// (every field `nil` on an ordinary URL).
public struct AccountLinkCallback: Sendable, Equatable {
    /// The grant to spend with ``CloudClient/linkAccountWithGrant(grant:rootSecret:signer:)``.
    public let grant: String?
    /// The account the grant is for, as the portal echoed it.
    public let accountId: String?
    /// `denied` when the person cancelled; `unexpected_callback` for a grant
    /// this app never asked for.
    public let error: String?

    public init(grant: String? = nil, accountId: String? = nil, error: String? = nil) {
        self.grant = grant
        self.accountId = accountId
        self.error = error
    }
}

/// The cloud's `/enable-ha` and `/disable-ha` pages: which namespace (group)
/// and context, and where the page sends the person back.
/// (== mero-js `EnableHAOptions` / `DisableHAOptions`.)
public struct HAPageOptions: Sendable, Equatable {
    public var groupId: String
    public var contextId: String
    public var redirectUrl: String?

    public init(groupId: String, contextId: String, redirectUrl: String? = nil) {
        self.groupId = groupId
        self.contextId = contextId
        self.redirectUrl = redirectUrl
    }
}

/// The refusals of ``CloudClient/enableHaAsAccount(namespaceId:salt:accountId:credential:keys:relayURL:ttlMs:)``
/// a person can act on — mero-js's `AccountNotLinkedError`,
/// `AccountLinkedToSeveralUsersError`, `HaRequestPendingError`,
/// `UnknownRelayError` and `RelayNotDialableError`. Each arrives as
/// ``AccountError/haRefused(code:status:body:)``; read it back with
/// ``AccountError/haRefusal``.
public enum HaRefusal: String, Sendable, Equatable, CaseIterable {
    /// 409: the account was never linked to a cloud user. Link it; retrying does not help.
    case accountNotLinked = "account_not_linked"
    /// 409: several cloud users linked this account. Unlink all but one.
    case accountLinkedToSeveralUsers = "account_linked_to_several_users"
    /// 409: another namespace of this account awaits its first fleet node.
    case haRequestPending = "ha_request_pending"
    /// 422: the cloud runs no relay at the claim's `relay_url`.
    case unknownRelay = "unknown_relay"
    /// 422: the relay has not reported its addresses yet; retry later.
    case relayNotDialable = "relay_not_dialable"

    /// The cloud's `error` code, verbatim (== mero-js `CODE`).
    public var code: String { rawValue }

    /// The HTTP status the cloud refuses with.
    public var status: Int {
        switch self {
        case .accountNotLinked, .accountLinkedToSeveralUsers, .haRequestPending: return 409
        case .unknownRelay, .relayNotDialable: return 422
        }
    }

    /// What to tell a person.
    public var message: String { CloudClient.haRefusalMessages[rawValue] ?? rawValue }
}

extension AccountError {
    /// The typed HA refusal this error is, or `nil`.
    public var haRefusal: HaRefusal? {
        guard case .haRefused(let code, let status, _) = self, let refusal = HaRefusal(rawValue: code),
            refusal.status == status
        else { return nil }
        return refusal
    }
}
