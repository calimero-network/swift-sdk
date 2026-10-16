import Foundation

// Root proofs for owner-level governance ops (core schema 18).
//
// Port of mero-js `src/owner-op/owner-op.ts`. A device key speaks for its
// account everywhere in governance, so a stolen device used to be enough to
// take a group from its owner. Core refuses the ops that can do that unless
// they carry an authorisation signed by the account's **root** key:
// `GroupOp::TransferOwnership`, `GroupOp::GroupDelete`, `RootOp::AdminChanged`
// (owner-only) and the TEE admission, release-admission and authoring
// policies (admin-level, but signed by the admin's own root).
//
// A node that holds the account root signs the proof itself. These are for a
// nodeless account, or a root kept cold, signing offline and passing the hex
// proof as `rootProof`. Byte layouts follow core's
// `calimero_account::OwnerOpAuthorization` and
// `calimero_governance_types::{GroupOp, RootOp}`; `OwnerOpTests` pins them to
// core's vectors (`crates/account/src/tests/owner_op.rs`,
// `root_guarded_vectors_are_stable`).

/// Which owner-level op a proof authorises. The raw value is the byte core
/// signs, its `OwnerOpKind` discriminant. (== mero-js `OWNER_OP_KIND`.)
public enum OwnerOpKind: UInt8, Sendable, CaseIterable, Equatable {
    case transferOwnership = 0
    case adminChanged = 1
    case groupDelete = 2
    case teeAdmissionPolicy = 3
    case teeAuthoringPolicy = 4
    case teeReleaseAdmissionPolicy = 5

    /// Whether only the group's owner may perform it. The TEE policies are
    /// admin-level, signed by the signing admin's own root.
    public var ownerOnly: Bool {
        switch self {
        case .transferOwnership, .adminChanged, .groupDelete: return true
        case .teeAdmissionPolicy, .teeAuthoringPolicy, .teeReleaseAdmissionPolicy: return false
        }
    }
}

/// Which plane the op is on: a `GroupOp` on a group, or a `RootOp` on the namespace.
public enum OwnerOpPlane: String, Sendable, Equatable {
    case group
    case root
}

/// An encoded owner-level op: its kind, its plane and its borsh bytes —
/// exactly what the node builds, and what the proof's digest covers.
public struct OwnerOp: Sendable, Equatable {
    public let kind: OwnerOpKind
    public let plane: OwnerOpPlane
    public let bytes: Data

    public init(kind: OwnerOpKind, plane: OwnerOpPlane, bytes: Data) {
        self.kind = kind
        self.plane = plane
        self.bytes = bytes
    }
}

/// core's owner-op constants: domains and the `GroupOp` / `RootOp` discriminants.
enum OwnerOpWire {
    static let signDomain = "calimero.account.owner-op.v1"
    static let bodyDomain = "calimero.account.owner-op.body.v1"
    /// A `RootKeyHandoff`: account 32, from_epoch u32, new root key 32, signature 64.
    static let handoffBytes = 32 + 4 + 32 + 64

    static let groupDelete: UInt8 = 14
    static let transferOwnership: UInt8 = 21
    static let teeAuthoringPolicySet: UInt8 = 33
    static let teeAdmissionPolicySetV2: UInt8 = 37
    static let teeReleaseAdmissionPolicySetV2: UInt8 = 38
    static let groupRootGuarded: UInt8 = 42

    static let adminChanged: UInt8 = 3
    static let rootRootGuarded: UInt8 = 12

    static func strings(_ values: [String], into w: inout BorshWriter) {
        w.u32(UInt32(values.count))
        for value in values { w.string(value) }
    }

    static func mode(_ mode: TeeAdmissionMode?) -> UInt8 {
        switch mode ?? .replica {
        case .replica: return 0
        case .relay: return 1
        }
    }
}

/// Hand the group to `newOwner` (an account, hex), who must already be an admin.
public func transferOwnershipOp(_ newOwner: String) throws -> OwnerOp {
    var w = BorshWriter()
    w.u8(OwnerOpWire.transferOwnership)
    w.raw(try Hex.decode(newOwner, label: "newOwner", bytes: 32))
    return OwnerOp(kind: .transferOwnership, plane: .group, bytes: w.data)
}

/// The owner-only deletion of a group that holds no contexts.
public func groupDeleteOp() -> OwnerOp {
    OwnerOp(kind: .groupDelete, plane: .group, bytes: Data([OwnerOpWire.groupDelete]))
}

/// Repoint the namespace's admin pin at `newAdmin` (an account, hex). A root op.
public func adminChangedOp(_ newAdmin: String) throws -> OwnerOp {
    var w = BorshWriter()
    w.u8(OwnerOpWire.adminChanged)
    w.raw(try Hex.decode(newAdmin, label: "newAdmin", bytes: 32))
    return OwnerOp(kind: .adminChanged, plane: .root, bytes: w.data)
}

/// The TEE authoring policy `PUT`/`DELETE …/settings/tee-authoring-policy`
/// publishes. `DELETE` publishes it with an empty list.
public func teeAuthoringPolicyOp(_ allowedMrtd: [String]) -> OwnerOp {
    var w = BorshWriter()
    w.u8(OwnerOpWire.teeAuthoringPolicySet)
    OwnerOpWire.strings(allowedMrtd, into: &w)
    return OwnerOp(kind: .teeAuthoringPolicy, plane: .group, bytes: w.data)
}

/// A measurement-list admission policy, as the node publishes it (the V2 form).
public struct TeeAdmissionPolicyOpInput: Sendable, Equatable {
    public var allowedMrtd: [String]
    public var allowedRtmr0: [String]
    public var allowedRtmr1: [String]
    public var allowedRtmr2: [String]
    public var allowedRtmr3: [String]
    public var allowedTcbStatuses: [String]
    public var acceptMock: Bool
    /// `nil` is the node's default, `replica`.
    public var mode: TeeAdmissionMode?

    public init(
        allowedMrtd: [String], allowedRtmr0: [String], allowedRtmr1: [String], allowedRtmr2: [String],
        allowedRtmr3: [String], allowedTcbStatuses: [String], acceptMock: Bool, mode: TeeAdmissionMode? = nil
    ) {
        self.allowedMrtd = allowedMrtd
        self.allowedRtmr0 = allowedRtmr0
        self.allowedRtmr1 = allowedRtmr1
        self.allowedRtmr2 = allowedRtmr2
        self.allowedRtmr3 = allowedRtmr3
        self.allowedTcbStatuses = allowedTcbStatuses
        self.acceptMock = acceptMock
        self.mode = mode
    }
}

/// The measurement-list admission policy `PUT …/settings/tee-admission-policy`
/// publishes. Pass the fields exactly as you send them: the node signs over
/// the op it builds from them, and any difference is a different op.
public func teeAdmissionPolicyOp(_ input: TeeAdmissionPolicyOpInput) -> OwnerOp {
    var w = BorshWriter()
    w.u8(OwnerOpWire.teeAdmissionPolicySetV2)
    OwnerOpWire.strings(input.allowedMrtd, into: &w)
    OwnerOpWire.strings(input.allowedRtmr0, into: &w)
    OwnerOpWire.strings(input.allowedRtmr1, into: &w)
    OwnerOpWire.strings(input.allowedRtmr2, into: &w)
    OwnerOpWire.strings(input.allowedRtmr3, into: &w)
    OwnerOpWire.strings(input.allowedTcbStatuses, into: &w)
    w.u8(input.acceptMock ? 1 : 0)
    w.u8(OwnerOpWire.mode(input.mode))
    return OwnerOp(kind: .teeAdmissionPolicy, plane: .group, bytes: w.data)
}

/// A signed-release admission policy, as the node publishes it (the V2 form).
public struct TeeReleaseAdmissionPolicyOpInput: Sendable, Equatable {
    public var allowedProfiles: [String]
    /// The oldest release admitted, in the node's normalised form (`X.Y.Z`,
    /// no `mero-tee-v` tag prefix): the node normalises what it is sent before
    /// it builds the op, and the proof must be for the op it builds.
    public var minReleaseVersion: String?
    public var allowedTcbStatuses: [String]
    public var acceptMock: Bool
    /// `nil` is the node's default, `replica`.
    public var mode: TeeAdmissionMode?

    public init(
        allowedProfiles: [String], minReleaseVersion: String? = nil, allowedTcbStatuses: [String],
        acceptMock: Bool, mode: TeeAdmissionMode? = nil
    ) {
        self.allowedProfiles = allowedProfiles
        self.minReleaseVersion = minReleaseVersion
        self.allowedTcbStatuses = allowedTcbStatuses
        self.acceptMock = acceptMock
        self.mode = mode
    }
}

/// The signed-release admission policy `PUT …/settings/tee-admission-policy` publishes.
public func teeReleaseAdmissionPolicyOp(_ input: TeeReleaseAdmissionPolicyOpInput) -> OwnerOp {
    var w = BorshWriter()
    w.u8(OwnerOpWire.teeReleaseAdmissionPolicySetV2)
    OwnerOpWire.strings(input.allowedProfiles, into: &w)
    if let minReleaseVersion = input.minReleaseVersion {
        w.u8(1)
        w.string(minReleaseVersion)
    } else {
        w.u8(0)
    }
    OwnerOpWire.strings(input.allowedTcbStatuses, into: &w)
    w.u8(input.acceptMock ? 1 : 0)
    w.u8(OwnerOpWire.mode(input.mode))
    return OwnerOp(kind: .teeReleaseAdmissionPolicy, plane: .group, bytes: w.data)
}

/// core's `OwnerOpAuthorization::op_digest`: the op's bytes, hashed under the body domain.
public func ownerOpDigest(_ opBytes: Data) -> Data {
    domainHash(OwnerOpWire.bodyDomain, [opBytes])
}

/// core's `OwnerOpTerms::signing_payload`: the 32 bytes the root signs.
public func ownerOpSigningPayload(
    account: String, namespaceId: String, groupId: String, kind: OwnerOpKind, opDigest: Data,
    counter: UInt64, keyEpoch: UInt32
) throws -> Data {
    domainHash(
        OwnerOpWire.signDomain,
        [
            try Hex.decode(account, label: "account", bytes: 32),
            try Hex.decode(namespaceId, label: "namespaceId", bytes: 32),
            try Hex.decode(groupId, label: "groupId", bytes: 32),
            Data([kind.rawValue]),
            opDigest,
            LittleEndian.u64(counter),
            LittleEndian.u32(keyEpoch),
        ])
}

/// What an owner-op proof binds, apart from the op and the key that signs it.
public struct OwnerOpProofInput: Sendable {
    /// The account root: its hex secret (never sent anywhere) or a ``Signer``.
    public var root: RootSource
    /// The namespace the op is published in (``GroupInfoResponseData/namespaceId``), hex.
    public var namespaceId: String
    /// The group the op acts on, hex. For `adminChanged` and the TEE policies,
    /// the namespace root.
    public var groupId: String
    /// The op, from one of the encoders here.
    public var op: OwnerOp
    /// The group's current guarded-op counter (``GroupInfoResponseData/ownerOpCounter``).
    public var counter: UInt64
    /// The root epoch that signs, 0 for a root never handed off. A later
    /// epoch needs `chain`.
    public var keyEpoch: UInt32
    /// The account's root-key handoffs, epoch 0 upward, each the hex borsh of
    /// a `RootKeyHandoff` (132 bytes). It must reach at least `keyEpoch`.
    public var chain: [String]

    public init(
        root: RootSource, namespaceId: String, groupId: String, op: OwnerOp, counter: UInt64,
        keyEpoch: UInt32 = 0, chain: [String] = []
    ) {
        self.root = root
        self.namespaceId = namespaceId
        self.groupId = groupId
        self.op = op
        self.counter = counter
        self.keyEpoch = keyEpoch
        self.chain = chain
    }

    /// mero-js's shape: the root as its 64-hex secret.
    public init(
        rootSecret: String, namespaceId: String, groupId: String, op: OwnerOp, counter: UInt64,
        keyEpoch: UInt32 = 0, chain: [String] = []
    ) {
        self.init(
            root: .secret(rootSecret), namespaceId: namespaceId, groupId: groupId, op: op, counter: counter,
            keyEpoch: keyEpoch, chain: chain)
    }
}

/// Sign a root proof for `input.op` and return it as core's `rootProof`: the
/// hex borsh of an `AccountProof<OwnerOpAuthorization>`.
///
/// Layout: `AccountGenesis` (version u8 + root pk 32), the handoff chain (u32
/// count + 132 bytes each), then `OwnerOpAuthorization` (account 32,
/// namespace 32, group 32, kind u8, op digest 32, counter u64, key epoch u32,
/// signature 64).
public func signOwnerOpProof(_ input: OwnerOpProofInput) async throws -> String {
    let root = try resolveRoot(input.root)
    let rootPublicKey = try Hex.decode(root.publicKey, label: "root publicKey", bytes: 32)
    var chain: [Data] = []
    for (index, handoff) in input.chain.enumerated() {
        let bytes = try Hex.decodeUnsized(handoff, label: "chain[\(index)]")
        guard bytes.count == OwnerOpWire.handoffBytes else {
            throw AccountError.invalidInput(
                "chain[\(index)] must be a \(OwnerOpWire.handoffBytes)-byte RootKeyHandoff, got \(bytes.count)")
        }
        chain.append(bytes)
    }
    guard Int(input.keyEpoch) <= chain.count else {
        throw AccountError.invalidInput(
            "keyEpoch \(input.keyEpoch) needs \(input.keyEpoch) handoffs in chain, got \(chain.count)")
    }

    let opDigest = ownerOpDigest(input.op.bytes)
    let payload = try ownerOpSigningPayload(
        account: root.accountId, namespaceId: input.namespaceId, groupId: input.groupId, kind: input.op.kind,
        opDigest: opDigest, counter: input.counter, keyEpoch: input.keyEpoch)
    let signature = try await signChecked(root.signer, payload)

    var w = BorshWriter()
    w.u8(DeviceCertificates.accountGenesisVersion)
    w.raw(rootPublicKey)
    w.u32(UInt32(chain.count))
    for handoff in chain { w.raw(handoff) }
    w.raw(try Hex.decode(root.accountId, label: "account", bytes: 32))
    w.raw(try Hex.decode(input.namespaceId, label: "namespaceId", bytes: 32))
    w.raw(try Hex.decode(input.groupId, label: "groupId", bytes: 32))
    w.u8(input.op.kind.rawValue)
    w.raw(opDigest)
    w.u64(input.counter)
    w.u32(input.keyEpoch)
    w.raw(signature)
    return Hex.encode(w.data)
}

/// The `RootGuarded` wrapper core publishes: the op and its proof, as one
/// `GroupOp` or `RootOp`. A client never sends this (the endpoints take the
/// proof and build the wrapper); it is here so the whole encoding is checkable
/// against core's vector.
public func rootGuardedOpBytes(_ op: OwnerOp, rootProof: String) throws -> Data {
    let wrapper = op.plane == .group ? OwnerOpWire.groupRootGuarded : OwnerOpWire.rootRootGuarded
    var out = Data([wrapper])
    out.append(op.bytes)
    out.append(try Hex.decodeUnsized(rootProof, label: "rootProof"))
    return out
}
