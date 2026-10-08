import Foundation

/// Minting a group invitation without a node: port of mero-js
/// `src/invitation/invitation.ts`.
///
/// An invitation is not a governance op. Nothing is published when one is
/// made: it is a bearer credential, `GroupInvitationFromAdmin` borsh-encoded,
/// hashed with SHA-256 and signed by the inviter's key. A node signs with its
/// namespace key; an account with no node signs here with its **device key**,
/// which peers resolve to the account through the namespace's device bindings
/// (bound when the account joined or founded the namespace) and then check for
/// admin or `CAN_INVITE_MEMBERS`.
///
/// Core: `crates/context/config/src/types.rs` (the types),
/// `crates/context/src/handlers/create_group_invitation.rs`
/// (`sign(sha256(borsh(invitation)))`).
public enum GroupInvitations {
    /// core's `MAX_INVITATION_VALIDITY_SECS`: one day.
    public static let maxValiditySeconds = 24 * 60 * 60

    /// `invited_role` values, as core numbers them.
    public enum InvitedRole: Int, Sendable {
        case admin = 0
        case member = 1
        case readOnly = 2
    }

    /// `sha256(borsh(invitation))`: the 32 bytes the inviter's key signs.
    public static func hash(_ body: GroupInvitationFromAdmin) throws -> Data {
        sha256(try NamespaceOps.encodeGroupInvitation(body))
    }

    /// The admitters a node names when its caller names none: the group's
    /// admins, deduplicated and sorted by account bytes (core's `BTreeSet`).
    public static func defaultAdmitters(_ members: [GroupMember]) -> [String] {
        // Lowercase hex sorts as the bytes do.
        Array(Set(members.filter { $0.role == "Admin" }.map { $0.identity.lowercased() })).sorted()
    }

    /// Sign an invitation to `groupId` with the device key, in the JSON shape a
    /// node's `createGroupInvitation` returns, so it goes to a join unchanged.
    ///
    /// - Parameters:
    ///   - admitters: accounts permitted to admit a claim (signed). Empty means
    ///     "the group's admins", derived from `members`; an invitation with no
    ///     admitters (claimable by broadcast) is never produced.
    ///   - validForSeconds: clamped to ``maxValiditySeconds`` (also the default).
    ///   - admitterAddrs: unsigned bootstrap hints where to reach an admitter.
    ///   - applicationId, appKey: unsigned bootstrap, 64 hex each.
    public static func sign(
        groupId: String, inviterAccount: String, keys: DeviceKeys, admitters: [String] = [],
        members: [GroupMember]? = nil, invitedRole: InvitedRole = .member,
        validForSeconds: Int = GroupInvitations.maxValiditySeconds, now: Int? = nil, nonce: Data? = nil,
        applicationId: String? = nil, appKey: String? = nil, admitterAddrs: [String] = []
    ) throws -> SignedGroupOpenInvitation {
        let inviterKey = try Ed25519.publicKey(seed: keys.signSecret)
        let group = try Hex.decode(groupId, label: "groupId", bytes: 32)
        _ = try Hex.decode(inviterAccount, label: "inviterAccount", bytes: 32)

        var named = admitters.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if named.isEmpty {
            guard let members else {
                throw AccountError.invalidInput(
                    "name the admitters, or pass the group members to default them to its admins: "
                        + "an invitation with no admitters is claimable by broadcast")
            }
            named = defaultAdmitters(members)
            guard !named.isEmpty else {
                throw AccountError.invalidInput(
                    "the member list names no admin, so there is nobody to default the admitters to")
            }
        }
        for (i, admitter) in named.enumerated() { _ = try Hex.decode(admitter, label: "admitters[\(i)]", bytes: 32) }

        let validFor = min(validForSeconds, maxValiditySeconds)
        guard validFor > 0 else {
            throw AccountError.invalidInput("validForSeconds must be positive, got \(validForSeconds)")
        }
        let salt = nonce ?? randomBytes(32)
        guard salt.count == 32 else { throw AccountError.invalidInput("nonce must be 32 bytes, got \(salt.count)") }

        let body = GroupInvitationFromAdmin(
            inviterIdentity: inviterKey.map { Int($0) }, groupId: group.map { Int($0) },
            expirationTimestamp: (now ?? Int(Date().timeIntervalSince1970)) + validFor,
            secretSalt: salt.map { Int($0) }, invitedRole: invitedRole.rawValue, admitters: named)
        let signature = try keys.sign(try hash(body))
        guard signature.count == 64 else {
            throw AccountError.protocolViolation("signer returned \(signature.count) bytes, expected 64")
        }
        return SignedGroupOpenInvitation(
            invitation: body, inviterSignature: Hex.encode(signature),
            inviterAccount: inviterAccount.trimmingCharacters(in: .whitespaces).lowercased(),
            admitterAddrs: admitterAddrs,
            applicationId: try applicationId.map {
                try Hex.decode($0, label: "applicationId", bytes: 32).map { Int($0) }
            },
            appKey: try appKey.map { try Hex.decode($0, label: "appKey", bytes: 32).map { Int($0) } })
    }
}
