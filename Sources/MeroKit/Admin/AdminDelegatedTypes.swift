// Types for the admin surface core added between 0.11.0-rc.41 and rc.83:
// account-session reads, delegated (relay) intents, account-root signing,
// device linking, sealing to an account, and root-guarded owner ops.
//
// The warrants, proofs and ops these carry are hex-encoded borsh that the
// caller signs. This file only moves them over the wire; it does not mint them.

import Foundation

// MARK: - Context reads (POST /contexts/{id}/query)

/// Body for ``AdminApi/queryContext(_:request:)``.
public struct QueryContextRequest: Codable, Sendable {
    /// A method declared read-only in the app's ABI. A write is a `409`.
    public var method: String
    /// The method's arguments, as the JSON the guest receives.
    public var argsJson: JSONValue
    public init(method: String, argsJson: JSONValue = .object([:])) {
        self.method = method; self.argsJson = argsJson
    }
}

public struct QueryContextResponseData: Codable, Sendable {
    /// The method's own return value.
    public let returns: JSONValue?
    public init(returns: JSONValue? = nil) { self.returns = returns }
}

// MARK: - Intent relay discovery (GET /contexts/{id}/intents)

/// What a node says about running intents in one context. Read it before
/// minting a warrant: one naming the wrong executor, key or release is refused
/// after it has already spent a nonce.
public struct IntentRelayInfo: Codable, Sendable, Equatable {
    /// The account a warrant for this node must name as `executor`, 64 hex.
    public let executorAccount: String
    /// The key a warrant for this node must name as `executor_key`, 64 hex.
    public let executorKey: String
    /// Whether this node holds `CAN_AUTHOR_ON_BEHALF` on the owning group.
    /// `false` is the default state of every context, not an error.
    public let canAuthorOnBehalf: Bool
    /// The group whose admin must grant that capability.
    public let groupId: String
    /// The group the capability was granted on, when it was granted on an
    /// ancestor rather than on ``groupId`` itself.
    public let grantedOnGroupId: String?
    /// The release blob id a warrant must pin as `release_bytecode_id`, 64 hex.
    public let releaseBytecodeId: String
    /// That release's semver, for the warrant's `release_version`.
    public let releaseVersion: String
    public init(
        executorAccount: String, executorKey: String, canAuthorOnBehalf: Bool, groupId: String,
        grantedOnGroupId: String? = nil, releaseBytecodeId: String, releaseVersion: String
    ) {
        self.executorAccount = executorAccount; self.executorKey = executorKey
        self.canAuthorOnBehalf = canAuthorOnBehalf; self.groupId = groupId
        self.grantedOnGroupId = grantedOnGroupId
        self.releaseBytecodeId = releaseBytecodeId; self.releaseVersion = releaseVersion
    }
}

// MARK: - Warrant nonces

/// Where an author device stands in its warrant-nonce sequence.
///
/// Every `u64` is a `UInt64` and decoded exactly: a nonce rounded through a
/// `Double` past 2^53 looks ordinary and is refused forever.
public struct WarrantNonceState: Codable, Sendable, Equatable {
    public let contextId: String
    public let authorDeviceKey: String
    /// Whether the node has seen any warrant from this device here.
    public let seen: Bool
    /// The highest nonce spent, `nil` when none.
    public let highWaterNonce: UInt64?
    public let windowWidth: UInt64
    /// The next nonce to mint at. `nil` means the sequence is exhausted
    /// (`u64::MAX` is spent): the node omits it rather than wrap to `0`.
    public let nextNonce: UInt64?

    public var isExhausted: Bool { nextNonce == nil }

    public init(
        contextId: String, authorDeviceKey: String, seen: Bool, highWaterNonce: UInt64? = nil,
        windowWidth: UInt64 = 0, nextNonce: UInt64?
    ) {
        self.contextId = contextId; self.authorDeviceKey = authorDeviceKey; self.seen = seen
        self.highWaterNonce = highWaterNonce; self.windowWidth = windowWidth; self.nextNonce = nextNonce
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextId = try c.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        authorDeviceKey = try c.decodeIfPresent(String.self, forKey: .authorDeviceKey) ?? ""
        let next = try c.decodeIfPresent(UInt64.self, forKey: .nextNonce)
        nextNonce = next
        windowWidth = try c.decodeIfPresent(UInt64.self, forKey: .windowWidth) ?? 0
        let high = try c.decodeIfPresent(UInt64.self, forKey: .highWaterNonce)
        if next == nil {
            // Exhausted: it has necessarily been seen, at the top of the range.
            seen = true
            highWaterNonce = high ?? UInt64.max
        } else {
            seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
            highWaterNonce = high
        }
    }

    enum CodingKeys: String, CodingKey {
        case contextId, authorDeviceKey, seen, highWaterNonce, windowWidth, nextNonce
    }

    /// Parse the route's `{ data: ... }` body.
    static func parse(_ body: Data) throws -> WarrantNonceState {
        struct Env: Decodable { let data: WarrantNonceState? }
        let env: Env
        do {
            env = try JSONDecoder().decode(Env.self, from: body)
        } catch {
            throw MeroError.decoding("warrant-nonce response: \(error)")
        }
        guard let data = env.data else { throw MeroError.emptyResponse("warrant-nonce response had no `data`") }
        return data
    }
}

struct WarrantNonceAsAuthorRequest: Codable, Sendable {
    let authorProof: String
}

// MARK: - Delegated intents (relay routes)

/// Body for `POST /contexts/{id}/presence-intents`: a presence update the
/// author's device signed (`calimero/presence/1` statement).
public struct PresenceIntentRequest: Codable, Sendable {
    /// Hex of the presence slice, or `nil` to retract. Sent as `null`, not
    /// omitted: the node reads an absent field as a malformed body.
    public var state: String?
    public var seq: UInt64
    public var sentAtMs: UInt64
    /// Hex, 64 bytes: the device key's signature over the statement.
    public var signature: String
    /// Hex borsh `AccountProof<DeviceCert>` tying the device to its account.
    public var authorProof: String
    public init(state: String?, seq: UInt64, sentAtMs: UInt64, signature: String, authorProof: String) {
        self.state = state; self.seq = seq; self.sentAtMs = sentAtMs
        self.signature = signature; self.authorProof = authorProof
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(seq, forKey: .seq)
        try c.encode(sentAtMs, forKey: .sentAtMs)
        try c.encode(signature, forKey: .signature)
        try c.encode(authorProof, forKey: .authorProof)
    }

    enum CodingKeys: String, CodingKey { case state, seq, sentAtMs, signature, authorProof }
}

/// `GET /groups/{id}/context-intents`: what a node can do to create contexts
/// in a group on a member's behalf.
public struct ContextIntentRelayInfo: Codable, Sendable, Equatable {
    public let executorAccount: String
    public let executorKey: String
    public let groupId: String
    public let canCreateOnBehalf: Bool
    /// Present only when the request named an `author`.
    public let authorMayCreate: Bool?
    public init(
        executorAccount: String, executorKey: String, groupId: String, canCreateOnBehalf: Bool,
        authorMayCreate: Bool? = nil
    ) {
        self.executorAccount = executorAccount; self.executorKey = executorKey; self.groupId = groupId
        self.canCreateOnBehalf = canCreateOnBehalf; self.authorMayCreate = authorMayCreate
    }
}

/// Body for `POST /groups/{id}/context-intents`.
public struct CreateContextIntentRequest: Codable, Sendable {
    /// Hex borsh `ContextCreationWarrant`.
    public var warrant: String
    /// Hex borsh `AccountProof<DeviceCert>`.
    public var authorProof: String
    /// The context's init arguments, as JSON. The warrant's `init_hash` commits to them.
    public var initArgs: JSONValue
    public init(warrant: String, authorProof: String, initArgs: JSONValue = .object([:])) {
        self.warrant = warrant; self.authorProof = authorProof; self.initArgs = initArgs
    }
}

public struct CreateContextIntentResponseData: Codable, Sendable, Equatable {
    public let contextId: String
    public let groupId: String
    public let memberPublicKey: String
    public init(contextId: String, groupId: String, memberPublicKey: String) {
        self.contextId = contextId; self.groupId = groupId; self.memberPublicKey = memberPublicKey
    }
}

/// `GET /groups/{id}/governance-intents`.
public struct GovernanceIntentRelayInfo: Codable, Sendable, Equatable {
    public let executorAccount: String
    public let executorKey: String
    public let groupId: String
    public let canActOnBehalf: Bool
    public init(executorAccount: String, executorKey: String, groupId: String, canActOnBehalf: Bool) {
        self.executorAccount = executorAccount; self.executorKey = executorKey; self.groupId = groupId
        self.canActOnBehalf = canActOnBehalf
    }
}

/// Body for `POST /groups/{id}/governance-intents`.
public struct GovernanceIntentRequest: Codable, Sendable {
    /// Hex borsh `GovernanceWarrant`.
    public var warrant: String
    /// Hex borsh `AccountProof<DeviceCert>`.
    public var authorProof: String
    /// Hex borsh `GroupOp` or `RootOp`, as the warrant's `kind` says.
    public var op: String
    public init(warrant: String, authorProof: String, op: String) {
        self.warrant = warrant; self.authorProof = authorProof; self.op = op
    }
}

public struct GovernanceIntentResponseData: Codable, Sendable, Equatable {
    public let groupId: String
    public let teeEnabled: Bool?
    public let teeError: String?
    public init(groupId: String, teeEnabled: Bool? = nil, teeError: String? = nil) {
        self.groupId = groupId; self.teeEnabled = teeEnabled; self.teeError = teeError
    }
}

// MARK: - Account root signing (POST /account/sign-with-root)

/// Body for ``AdminApi/signWithAccountRoot(_:)``.
public struct AccountSignWithRootRequest: Codable, Sendable {
    /// The verifier's domain, e.g. ``linkDomain``.
    public var domain: String
    /// The bytes to sign after the domain, hex. At most 4096 bytes.
    public var payload: String
    public init(domain: String, payload: String) { self.domain = domain; self.payload = payload }

    /// Hex-encode a text challenge's UTF-8 bytes for ``payload``.
    public init(domain: String, text: String) {
        self.init(domain: domain, payload: text.utf8.map { String(format: "%02x", $0) }.joined())
    }

    public static let linkDomain = "mdma.account-link"
    public static let loginDomain = "mdma.account-login"
    public static let recoveryDomain = "mdma.account-recovery"
}

public struct AccountSignWithRootResponseData: Codable, Sendable, Equatable {
    /// The account root's public key, 64 hex.
    public let rootPublicKey: String
    /// The signature over `domain ‖ payload`, **base64**.
    public let signature: String
    /// The account the root belongs to, 64 hex.
    public let accountId: String
    public init(rootPublicKey: String, signature: String, accountId: String) {
        self.rootPublicKey = rootPublicKey; self.signature = signature; self.accountId = accountId
    }
}

// MARK: - Device linking (POST /namespaces/{id}/account/link-device)

public struct LinkAccountDeviceRequest: Codable, Sendable {
    /// Hex borsh `AccountProof<DeviceCert>`.
    public var credential: String
    /// Hex borsh `AccountProof<DeviceScope>`. Must reach this namespace's app.
    public var scope: String
    public init(credential: String, scope: String) { self.credential = credential; self.scope = scope }
}

public struct LinkAccountDeviceResponseData: Codable, Sendable, Equatable {
    public let accountId: String
    public let deviceId: String
    /// The namespace already bound this device, so nothing was published.
    public let alreadyBound: Bool
    public init(accountId: String, deviceId: String, alreadyBound: Bool) {
        self.accountId = accountId; self.deviceId = deviceId; self.alreadyBound = alreadyBound
    }
}

// MARK: - Sealing to an account (POST /groups/{id}/accounts/{account}/seal)

public struct SealToAccountRequest: Codable, Sendable {
    /// Hex plaintext. Small by design; the node caps it.
    public var plaintext: String
    public init(plaintext: String) { self.plaintext = plaintext }
}

/// A payload sealed to an account's root key.
public struct SealedEnvelope: Codable, Sendable, Equatable {
    /// The root-key epoch it was sealed under.
    public let accountRootEpoch: UInt64
    /// Hex, 32 bytes: the one-shot sender key.
    public let ephemeralPublicKey: String
    /// Hex, 12 bytes: the AES-256-GCM nonce.
    public let nonce: String
    /// Hex: ciphertext with its 16-byte tag appended.
    public let ciphertext: String
    public init(accountRootEpoch: UInt64, ephemeralPublicKey: String, nonce: String, ciphertext: String) {
        self.accountRootEpoch = accountRootEpoch; self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce; self.ciphertext = ciphertext
    }
}

// MARK: - Delegated execution grants

/// What ``AdminApi/openToDelegatedExecution(_:)`` and
/// ``AdminApi/grantAuthorship(_:account:)`` did.
public struct DelegatedExecutionChange: Sendable, Equatable {
    /// Whether an op was published. `false` when the bit was already set.
    public let changed: Bool
    /// The resulting capability mask.
    public let capabilities: Int
    public init(changed: Bool, capabilities: Int) { self.changed = changed; self.capabilities = capabilities }
}

// MARK: - Root-guarded owner ops

/// The optional owner proof every root-guarded op takes.
public struct RootGuardedOpRequest: Codable, Sendable {
    /// Hex borsh `AccountProof<OwnerOpAuthorization>`. Omit it on a node that
    /// holds the owner's account root. Never send `""`; that is a `400`.
    public var rootProof: String?
    public init(rootProof: String? = nil) { self.rootProof = rootProof }
}

public typealias OwnerDeleteGroupRequest = RootGuardedOpRequest

public struct TransferOwnershipRequest: Codable, Sendable {
    /// The new owner's account, 64 hex. It must already be an admin.
    public var newOwner: String
    public var rootProof: String?
    public init(newOwner: String, rootProof: String? = nil) { self.newOwner = newOwner; self.rootProof = rootProof }
}

public struct ChangeNamespaceAdminRequest: Codable, Sendable {
    /// The new admin's account, 64 hex, a member of the namespace root.
    public var newAdmin: String
    public var rootProof: String?
    public init(newAdmin: String, rootProof: String? = nil) { self.newAdmin = newAdmin; self.rootProof = rootProof }
}

public struct SetTeeAuthoringPolicyRequest: Codable, Sendable {
    /// MRTDs of the TEEs that may author. Empty turns TEE authorship off.
    public var allowedMrtd: [String]
    public var rootProof: String?
    public init(allowedMrtd: [String], rootProof: String? = nil) {
        self.allowedMrtd = allowedMrtd; self.rootProof = rootProof
    }
}

// MARK: - Ownership proofs

/// Body for the typed ``AdminApi/issueOwnershipProof(_:request:)``.
public struct IssueOwnershipProofRequest: Codable, Sendable {
    public var audience: String
    /// Hex, 32 bytes.
    public var contextId: String
    public var subject: String
    /// Hex, 32–128 characters.
    public var nonce: String
    /// Unix milliseconds. The node clamps it to five minutes out.
    public var expiresAtMs: UInt64
    public init(audience: String, contextId: String, subject: String, nonce: String, expiresAtMs: UInt64) {
        self.audience = audience; self.contextId = contextId; self.subject = subject
        self.nonce = nonce; self.expiresAtMs = expiresAtMs
    }
}

/// Body for the typed ``AdminApi/issueNamespaceOwnershipProof(_:request:)``.
public struct IssueNamespaceOwnershipProofRequest: Codable, Sendable {
    public var audience: String
    public var subject: String
    public var nonce: String
    public var expiresAtMs: UInt64
    public init(audience: String, subject: String, nonce: String, expiresAtMs: UInt64) {
        self.audience = audience; self.subject = subject; self.nonce = nonce; self.expiresAtMs = expiresAtMs
    }
}

public struct IssueOwnershipProofResponseData: Codable, Sendable, Equatable {
    /// Hex ed25519 public key of the signer.
    public let signerPublicKey: String
    /// Base64 of the canonical claim bytes. Verify against these exact bytes.
    public let signedPayload: String
    /// Base64 ed25519 signature.
    public let signature: String
    /// Namespace proofs only: what the namespace id was derived from.
    public let founding: NamespaceFounding?
    /// Namespace proofs only: hex borsh `AccountProof<DeviceCert>` certifying
    /// the signer into the founding account.
    public let credential: String?
    public init(
        signerPublicKey: String, signedPayload: String, signature: String,
        founding: NamespaceFounding? = nil, credential: String? = nil
    ) {
        self.signerPublicKey = signerPublicKey; self.signedPayload = signedPayload; self.signature = signature
        self.founding = founding; self.credential = credential
    }
}
