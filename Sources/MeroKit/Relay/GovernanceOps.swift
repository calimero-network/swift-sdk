import Foundation

/// A group member's role in a governance op. Borsh discriminants follow core's
/// `GroupMemberRole`; the two TEE roles (3, 4) come only from attestation, never
/// from a member's op, so they are not offered.
public enum GovernanceMemberRole: String, Sendable, CaseIterable {
    case admin = "Admin"
    case member = "Member"
    case readOnly = "ReadOnly"

    var byte: UInt8 {
        switch self {
        case .admin: return 0
        case .member: return 1
        case .readOnly: return 2
        }
    }
}

/// A new subgroup's create: its derived id, the salt it was derived with, and the op.
public struct SubgroupCreation: Sendable, Equatable {
    public let groupId: String
    public let salt: String
    public let op: Warrants.GovernanceOp
}

/// Encoders for the governance ops a member may have a relay publish for them.
///
/// Port of mero-js `src/warrant/governance-op.ts`. A governance warrant commits
/// to an op's **borsh bytes**, so these produce exactly what the node decodes:
/// each discriminant is the variant's position in core's `GroupOp` / `RootOp`
/// (`crates/governance-types/src/lib.rs`, checked against 0.11.0-rc.83).
///
/// **Delegable form.** A removal, a leave and a cascade delete carry fields
/// only the publisher can compute (post-state hashes, the enumerated subtree);
/// the member signs them cleared, and only the cleared form is produced here.
public enum GovernanceOps {
    /// `GroupOp` discriminants.
    enum GroupOp {
        static let memberAdded: UInt8 = 1
        static let memberRemoved: UInt8 = 2
        static let memberLeft: UInt8 = 3
        static let memberRoleSet: UInt8 = 4
        static let memberCapabilitySet: UInt8 = 5
        static let defaultCapabilitiesSet: UInt8 = 6
        static let targetApplicationSet: UInt8 = 7
        static let contextDetached: UInt8 = 9
        static let subgroupVisibilitySet: UInt8 = 10
        static let groupMetadataSet: UInt8 = 11
        static let memberMetadataSet: UInt8 = 12
        static let contextMetadataSet: UInt8 = 13
        static let contextCapabilityGranted: UInt8 = 16
        static let contextCapabilityRevoked: UInt8 = 17
    }

    /// `RootOp` discriminants.
    enum RootOp {
        static let groupCreated: UInt8 = 0
        static let groupReparented: UInt8 = 1
        static let groupDeleted: UInt8 = 2
        static let memberJoinedOpen: UInt8 = 7
        static let namespaceCreatedV2: UInt8 = 9
    }

    /// core's `NAMESPACE_ID_DOMAIN`.
    static let namespaceIdDomain = "calimero.namespace.id.v1"
    /// core's `SUBGROUP_ID_DOMAIN`.
    static let subgroupIdDomain = "calimero.subgroup.id.v1"

    private static let clearedHash = Data(count: 32)
    private static let emptyVec = LittleEndian.u32(0)

    // MARK: - Group ops

    /// Add `member` (an account, hex) with `role`. Adding a `Member` needs
    /// `MANAGE_MEMBERS` or admin; adding an `Admin` needs admin.
    public static func memberAdded(_ member: String, role: GovernanceMemberRole) throws -> Warrants.GovernanceOp {
        group(GroupOp.memberAdded, try h32(member, "member"), Data([role.byte]))
    }

    /// Remove `member`, delegable form: both post-state claims cleared.
    public static func memberRemoved(_ member: String) throws -> Warrants.GovernanceOp {
        group(GroupOp.memberRemoved, try h32(member, "member"), clearedHash, emptyVec)
    }

    /// The author leaves the group, delegable form. Applied only when `member`
    /// is the author's own account.
    public static func memberLeft(_ member: String) throws -> Warrants.GovernanceOp {
        group(GroupOp.memberLeft, try h32(member, "member"), clearedHash, emptyVec)
    }

    /// Set `member`'s role.
    public static func memberRoleSet(_ member: String, role: GovernanceMemberRole) throws -> Warrants.GovernanceOp {
        group(GroupOp.memberRoleSet, try h32(member, "member"), Data([role.byte]))
    }

    /// Set `member`'s capabilities. `CAN_AUTHOR_ON_BEHALF` (bit 9) is refused.
    public static func memberCapabilitySet(_ member: String, capabilities: UInt32) throws -> Warrants.GovernanceOp {
        group(
            GroupOp.memberCapabilitySet, try h32(member, "member"),
            LittleEndian.u32(try relayableMask(capabilities, "capabilities")))
    }

    /// Set the group's default capability mask. Needs admin. A mask with
    /// `CAN_AUTHOR_ON_BEHALF` (bit 9) is refused before anything is signed:
    /// a relay never carries a change to it.
    public static func defaultCapabilitiesSet(_ capabilities: UInt32) throws -> Warrants.GovernanceOp {
        group(GroupOp.defaultCapabilitiesSet, LittleEndian.u32(try relayableMask(capabilities, "capabilities")))
    }

    /// Choose the application a group runs, delegable form: `bytecode_id` left
    /// for the relay (32 zero bytes), resolved from `package@version`. Through a
    /// relay this is accepted only as a group's **first** application.
    public static func targetApplicationSet(
        applicationId: String, package: String, version: String
    ) throws -> Warrants.GovernanceOp {
        group(
            GroupOp.targetApplicationSet, clearedHash, try h32(applicationId, "applicationId"),
            try nonEmptyString(package, "package"), try nonEmptyString(version, "version"))
    }

    /// Detach a context from the group.
    public static func contextDetached(_ contextId: String) throws -> Warrants.GovernanceOp {
        group(GroupOp.contextDetached, try h32(contextId, "contextId"))
    }

    /// Visibility of a subgroup.
    public enum SubgroupVisibility: Sendable { case open, restricted }

    /// Make a subgroup open (parent members may join it themselves) or restricted.
    public static func subgroupVisibilitySet(_ mode: SubgroupVisibility) -> Warrants.GovernanceOp {
        group(GroupOp.subgroupVisibilitySet, Data([mode == .open ? 0 : 1]))
    }

    /// Name the group, with optional key/value data.
    public static func groupMetadataSet(name: String? = nil, data: [String: String] = [:]) -> Warrants.GovernanceOp {
        group(GroupOp.groupMetadataSet, optionalString(name), stringMap(data))
    }

    /// Name a member in the group.
    public static func memberMetadataSet(
        _ member: String, name: String? = nil, data: [String: String] = [:]
    ) throws -> Warrants.GovernanceOp {
        group(GroupOp.memberMetadataSet, try h32(member, "member"), optionalString(name), stringMap(data))
    }

    /// Name a context in the group.
    public static func contextMetadataSet(
        _ contextId: String, name: String? = nil, data: [String: String] = [:]
    ) throws -> Warrants.GovernanceOp {
        group(GroupOp.contextMetadataSet, try h32(contextId, "contextId"), optionalString(name), stringMap(data))
    }

    /// Grant `member` a per-context capability (a non-zero `u8`).
    public static func contextCapabilityGranted(
        contextId: String, member: String, capability: UInt8
    ) throws -> Warrants.GovernanceOp {
        group(
            GroupOp.contextCapabilityGranted, try h32(contextId, "contextId"), try h32(member, "member"),
            try contextCapability(capability))
    }

    /// Revoke a per-context capability from `member`.
    public static func contextCapabilityRevoked(
        contextId: String, member: String, capability: UInt8
    ) throws -> Warrants.GovernanceOp {
        group(
            GroupOp.contextCapabilityRevoked, try h32(contextId, "contextId"), try h32(member, "member"),
            try contextCapability(capability))
    }

    // MARK: - Root ops

    /// core's `created_subgroup_id`:
    /// `domain_hash("calimero.subgroup.id.v1", [admin, parentId, [restricted], salt])`.
    public static func createdSubgroupId(
        admin: String, parentId: String, restricted: Bool, salt: String
    ) throws -> String {
        Hex.encode(
            domainHash(
                subgroupIdDomain,
                [
                    try h32(admin, "admin"), try h32(parentId, "parentId"), Data([restricted ? 1 : 0]),
                    try h32(salt, "salt"),
                ]))
    }

    /// Create a subgroup under `parentId` (a root op, posted to the namespace).
    /// `groupId` must be ``createdSubgroupId(admin:parentId:restricted:salt:)``;
    /// ``subgroupCreation(parentId:restricted:admin:salt:)`` derives it for you.
    public static func groupCreated(
        groupId: String, parentId: String, restricted: Bool, admin: String, salt: String
    ) throws -> Warrants.GovernanceOp {
        root(
            RootOp.groupCreated, try h32(groupId, "groupId"), try h32(parentId, "parentId"),
            Data([restricted ? 1 : 0]), try h32(admin, "admin"), try h32(salt, "salt"))
    }

    /// Draw a salt (unless given), derive the subgroup id, and encode the create.
    public static func subgroupCreation(
        parentId: String, restricted: Bool, admin: String, salt: String? = nil
    ) throws -> SubgroupCreation {
        let salt = try salt.map { Hex.encode(try h32($0, "salt")) } ?? Hex.encode(randomBytes(32))
        let groupId = try createdSubgroupId(admin: admin, parentId: parentId, restricted: restricted, salt: salt)
        return SubgroupCreation(
            groupId: groupId, salt: salt,
            op: try groupCreated(groupId: groupId, parentId: parentId, restricted: restricted, admin: admin, salt: salt)
        )
    }

    /// Move `childGroupId` under `newParentId`.
    public static func groupReparented(childGroupId: String, newParentId: String) throws -> Warrants.GovernanceOp {
        root(RootOp.groupReparented, try h32(childGroupId, "childGroupId"), try h32(newParentId, "newParentId"))
    }

    /// Delete `rootGroupId` and its subtree, delegable form: both cascade lists empty.
    public static func groupDeleted(_ rootGroupId: String) throws -> Warrants.GovernanceOp {
        root(RootOp.groupDeleted, try h32(rootGroupId, "rootGroupId"), emptyVec, emptyVec)
    }

    /// Join an open subgroup yourself. `member` must be the author; `credential`
    /// is the author's `AccountProof<DeviceCert>`, carried inline.
    public static func memberJoinedOpen(
        member: String, groupId: String, credential: String
    ) throws -> Warrants.GovernanceOp {
        root(
            RootOp.memberJoinedOpen, try h32(member, "member"), try h32(groupId, "groupId"),
            try Hex.decodeUnsized(credential, label: "credential"))
    }

    /// The id of the namespace `founder` founds with `salt`: core's
    /// `founded_namespace_id`, `domain_hash("calimero.namespace.id.v1", [founder, salt])`.
    public static func foundedNamespaceId(founder: String, salt: String) throws -> String {
        Hex.encode(domainHash(namespaceIdDomain, [try h32(founder, "founder"), try h32(salt, "salt")]))
    }

    /// Found a namespace: core's `RootOp::NamespaceCreatedV2` genesis,
    /// `[9] ‖ founder ‖ credential ‖ salt` (the credential is a nested struct,
    /// written inline). The warrant's scope must be
    /// ``foundedNamespaceId(founder:salt:)``.
    public static func namespaceCreated(
        founder: String, credential: String, salt: String
    ) throws -> Warrants.GovernanceOp {
        let credentialBytes = try Hex.decodeUnsized(credential, label: "credential")
        guard !credentialBytes.isEmpty else {
            throw AccountError.invalidInput("credential must be the founder's AccountProof<DeviceCert>, got nothing")
        }
        return root(RootOp.namespaceCreatedV2, try h32(founder, "founder"), credentialBytes, try h32(salt, "salt"))
    }

    // MARK: - Helpers

    private static func group(_ tag: UInt8, _ parts: Data...) -> Warrants.GovernanceOp {
        Warrants.GovernanceOp(kind: .group, bytes: parts.reduce(Data([tag]), +))
    }

    private static func root(_ tag: UInt8, _ parts: Data...) -> Warrants.GovernanceOp {
        Warrants.GovernanceOp(kind: .root, bytes: parts.reduce(Data([tag]), +))
    }

    private static func h32(_ value: String, _ label: String) throws -> Data {
        try Hex.decode(value, label: label, bytes: 32)
    }

    private static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return LittleEndian.u32(UInt32(bytes.count)) + bytes
    }

    private static func nonEmptyString(_ value: String, _ what: String) throws -> Data {
        guard !value.isEmpty else { throw AccountError.invalidInput("\(what) must not be empty") }
        return string(value)
    }

    private static func optionalString(_ value: String?) -> Data {
        value.map { Data([1]) + string($0) } ?? Data([0])
    }

    /// Borsh `BTreeMap<String, String>`: sorted by key **bytes**.
    private static func stringMap(_ data: [String: String]) -> Data {
        let entries = data.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
        return entries.reduce(LittleEndian.u32(UInt32(entries.count))) { $0 + string($1.key) + string($1.value) }
    }

    private static func relayableMask(_ capabilities: UInt32, _ what: String) throws -> UInt32 {
        if Capabilities.hasCap(capabilities, Capabilities.canAuthorOnBehalf) {
            throw AccountError.invalidInput(
                "\(what) may not include CAN_AUTHOR_ON_BEHALF (512): a relay never carries a change to it")
        }
        return capabilities
    }

    private static func contextCapability(_ capability: UInt8) throws -> Data {
        guard capability != 0 else { throw AccountError.invalidInput("capability must be a non-zero u8, got 0") }
        return Data([capability])
    }
}
