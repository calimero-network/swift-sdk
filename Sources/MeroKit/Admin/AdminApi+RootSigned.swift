import Foundation

/// The terms a root proof for one group binds, read from the node.
public struct OwnerOpTarget: Sendable, Equatable {
    /// The namespace the op is published in.
    public let namespaceId: String
    /// The group the op acts on (the namespace root for a root op).
    public let groupId: String
    /// The group's guarded-op counter the proof must name.
    public let counter: UInt64

    public init(namespaceId: String, groupId: String, counter: UInt64) {
        self.namespaceId = namespaceId
        self.groupId = groupId
        self.counter = counter
    }
}

// MARK: - Root-guarded owner ops, signed by the SDK

/// The root-guarded owner ops, with the proof minted here from the account
/// root instead of passed in as `rootProof` — for a nodeless account, or a
/// root kept cold on this device (``KeychainRootSeedVault``).
///
/// Each reads ``GroupInfoResponseData/namespaceId`` and
/// ``GroupInfoResponseData/ownerOpCounter`` with ``getGroupInfo(_:)``, builds
/// the op exactly as the node will (``transferOwnershipOp(_:)`` and friends),
/// signs it with ``signOwnerOpProof(_:)``, and sends it. A `409` means the
/// counter moved in between: call again. The raw-`rootProof` forms stay for a
/// proof signed elsewhere.
public extension AdminApi {
    /// The namespace, group and counter a proof for `op` on `groupId` names.
    /// For a root op (`adminChanged`) the group is the namespace root.
    func ownerOpTarget(_ groupId: String, plane: OwnerOpPlane) async throws -> OwnerOpTarget {
        let info = try await getGroupInfo(groupId)
        guard let counter = info.ownerOpCounter else {
            throw AccountError.protocolViolation(
                "group \(groupId) reports no ownerOpCounter: the node predates root-guarded owner ops (core rc.83)")
        }
        let namespaceId = info.namespaceId ?? groupId
        return OwnerOpTarget(
            namespaceId: namespaceId, groupId: plane == .root ? namespaceId : groupId, counter: counter)
    }

    /// Sign the `rootProof` for `op` on `groupId`, reading its terms from the node.
    func signRootProof(
        _ groupId: String, op: OwnerOp, root: RootSource, keyEpoch: UInt32 = 0, chain: [String] = []
    ) async throws -> String {
        let target = try await ownerOpTarget(groupId, plane: op.plane)
        return try await signOwnerOpProof(
            OwnerOpProofInput(
                root: root, namespaceId: target.namespaceId, groupId: target.groupId, op: op,
                counter: target.counter, keyEpoch: keyEpoch, chain: chain))
    }

    /// Hand `groupId` to `newOwner`, signing the owner's root proof here.
    func transferOwnership(
        _ groupId: String, newOwner: String, root: RootSource, keyEpoch: UInt32 = 0, chain: [String] = []
    ) async throws {
        let proof = try await signRootProof(
            groupId, op: try transferOwnershipOp(newOwner), root: root, keyEpoch: keyEpoch, chain: chain)
        try await transferOwnership(groupId, request: TransferOwnershipRequest(newOwner: newOwner, rootProof: proof))
    }

    /// Point the namespace's admin at `newAdmin`, signing the owner's root proof here.
    func changeNamespaceAdmin(
        _ namespaceId: String, newAdmin: String, root: RootSource, keyEpoch: UInt32 = 0, chain: [String] = []
    ) async throws {
        let proof = try await signRootProof(
            namespaceId, op: try adminChangedOp(newAdmin), root: root, keyEpoch: keyEpoch, chain: chain)
        try await changeNamespaceAdmin(
            namespaceId, request: ChangeNamespaceAdminRequest(newAdmin: newAdmin, rootProof: proof))
    }

    /// Delete an empty group through the owner-only path, signing the proof here.
    func ownerDeleteGroup(
        _ groupId: String, root: RootSource, keyEpoch: UInt32 = 0, chain: [String] = []
    ) async throws {
        let proof = try await signRootProof(groupId, op: groupDeleteOp(), root: root, keyEpoch: keyEpoch, chain: chain)
        try await ownerDeleteGroup(groupId, request: RootGuardedOpRequest(rootProof: proof))
    }

    /// Set the namespace's TEE authoring policy, signing the admin's root proof here.
    func setTeeAuthoringPolicy(
        _ groupId: String, allowedMrtd: [String], root: RootSource, keyEpoch: UInt32 = 0, chain: [String] = []
    ) async throws {
        let proof = try await signRootProof(
            groupId, op: teeAuthoringPolicyOp(allowedMrtd), root: root, keyEpoch: keyEpoch, chain: chain)
        try await setTeeAuthoringPolicy(
            groupId, request: SetTeeAuthoringPolicyRequest(allowedMrtd: allowedMrtd, rootProof: proof))
    }

    /// Turn TEE authorship off (the policy with no MRTDs), signing the proof here.
    func disableTeeAuthoringPolicy(
        _ groupId: String, root: RootSource, keyEpoch: UInt32 = 0, chain: [String] = []
    ) async throws {
        let proof = try await signRootProof(
            groupId, op: teeAuthoringPolicyOp([]), root: root, keyEpoch: keyEpoch, chain: chain)
        try await disableTeeAuthoringPolicy(groupId, request: RootGuardedOpRequest(rootProof: proof))
    }

    /// Set the namespace's TEE admission policy, signing the admin's root
    /// proof over the op the node builds from `request` (its `rootProof` is
    /// replaced).
    func setTeeAdmissionPolicy(
        _ groupId: String, request: SetTeeAdmissionPolicyRequest, root: RootSource, keyEpoch: UInt32 = 0,
        chain: [String] = []
    ) async throws {
        var body = request
        body.rootProof = try await signRootProof(
            groupId, op: try request.ownerOp(), root: root, keyEpoch: keyEpoch, chain: chain)
        try await setTeeAdmissionPolicy(groupId, request: body)
    }

    /// Bind a device of a nodeless account into `namespaceId`, signing its
    /// scope (``signDeviceScope(_:)``) with the account root here.
    func linkAccountDevice(
        _ namespaceId: String, credential: String, scope: DeviceScopeInput
    ) async throws -> LinkAccountDeviceResponseData {
        let signedScope = try await signDeviceScope(scope)
        return try await linkAccountDevice(
            namespaceId, request: LinkAccountDeviceRequest(credential: credential, scope: signedScope))
    }
}

public extension SetTeeAdmissionPolicyRequest {
    /// The `GroupOp` the node builds from this request, and the root proof
    /// must name: ``teeReleaseAdmissionPolicyOp(_:)`` for the signed-release
    /// form (its `minReleaseVersion` normalised as the node normalises it),
    /// ``teeAdmissionPolicyOp(_:)`` otherwise.
    func ownerOp() throws -> OwnerOp {
        if let signedRelease {
            return teeReleaseAdmissionPolicyOp(
                TeeReleaseAdmissionPolicyOpInput(
                    allowedProfiles: signedRelease.allowedProfiles,
                    minReleaseVersion: try signedRelease.minReleaseVersion.map(normalizeTeeReleaseVersion),
                    allowedTcbStatuses: allowedTcbStatuses, acceptMock: acceptMock, mode: mode))
        }
        return teeAdmissionPolicyOp(
            TeeAdmissionPolicyOpInput(
                allowedMrtd: allowedMrtd, allowedRtmr0: allowedRtmr0, allowedRtmr1: allowedRtmr1,
                allowedRtmr2: allowedRtmr2, allowedRtmr3: allowedRtmr3, allowedTcbStatuses: allowedTcbStatuses,
                acceptMock: acceptMock, mode: mode))
    }
}

/// core's `normalize_release_version(raw, NODE_RELEASE_TAG_PREFIX)`: trimmed,
/// without a leading `mero-tee-v`. Throws on an empty version (the node's `400`).
public func normalizeTeeReleaseVersion(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AccountError.invalidInput("release version cannot be empty") }
    let prefix = "mero-tee-v"
    return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
}
