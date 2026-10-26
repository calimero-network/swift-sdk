import Foundation
import MeroKit

// The write hooks of mero-react (`src/hooks/index.ts`), one ``AsyncMutation``
// per family: `isLoading`, `error` and `failure` are shared by the family's
// calls. Each call resolves `nil` with no client (nothing is sent) and on
// failure (recorded in `error`); the join calls rethrow instead when made with
// `throwOnError: true`.
//
// Every call goes through ``MeroClient/admin``, so the same call works on a
// node (``NodeAdmin``) and as an account (``AccountAdmin``).

/// A base for the families: the client they write through.
@MainActor
open class MeroMutation: AsyncMutation {
    public private(set) weak var client: MeroClient?

    public init(client: MeroClient, throwOnError: Bool = false) {
        self.client = client
        super.init(throwOnError: throwOnError)
    }

    /// The session's admin, or `nil` when there is none.
    public var admin: (any AdminSurface)? { client?.admin }

    /// `action` over ``admin``; `nil`, sending nothing, with no admin.
    func withAdmin<T: Sendable>(_ action: @Sendable (any AdminSurface) async throws -> T) async -> T? {
        guard let admin else { return nil }
        return await attempt { try await action(admin) }
    }
}

/// What a private context is made of. (== mero-react `CreatePrivateContextRequest`.)
public struct CreatePrivateContextRequest: Sendable, Equatable {
    public var namespaceId: String
    public var applicationId: String
    /// The accounts that share it with you, and nobody else — the other person of a DM.
    public var members: [String]
    public var initializationParams: [Int]?

    public init(namespaceId: String, applicationId: String, members: [String], initializationParams: [Int]? = nil) {
        self.namespaceId = namespaceId
        self.applicationId = applicationId
        self.members = members
        self.initializationParams = initializationParams
    }
}

/// Context writes. (== mero-react `useCreateContext`, `useCreatePrivateContext`,
/// `useDeleteContext`, `useJoinSubgroupInheritance`, `useResyncContext`.)
@MainActor
public final class ContextActions: MeroMutation {
    /// Create a context; an account creates it through the relay serving the
    /// namespace, under a creation warrant.
    @discardableResult
    public func createContext(_ request: CreateContextRequest) async -> CreateContextResponseData? {
        await withAdmin { try await $0.createContext(request) }
    }

    /// A context only you and `members` are in: its own restricted group in the
    /// namespace, the members added directly, then the context. Same call on a
    /// node and as an account (each step under its own warrant there).
    @discardableResult
    public func createPrivateContext(_ request: CreatePrivateContextRequest) async -> String? {
        guard let client else { return nil }
        if let session = client.delegatedSession {
            let env = client.delegatedEnvironment
            return await attempt {
                try await DelegatedAccounts.createDelegatedPrivateContext(
                    session,
                    CreateDelegatedContextRequest(
                        namespaceId: request.namespaceId, applicationId: request.applicationId,
                        initializationParams: request.initializationParams),
                    members: request.members, env: env
                ).contextId
            }
        }
        return await withAdmin { admin in
            let group = try await admin.createGroupInNamespace(
                request.namespaceId, request: CreateGroupInNamespaceRequest(visibility: "restricted"))
            // The creator is the new group's admin already; the others join here.
            try await admin.addGroupMembers(
                group.groupId,
                request: AddGroupMembersRequest(
                    members: request.members.map { GroupMemberInput(identity: $0, role: "Member") }))
            return try await admin.createContext(
                CreateContextRequest(
                    applicationId: request.applicationId, groupId: group.groupId,
                    initializationParams: request.initializationParams)
            ).contextId
        }
    }

    @discardableResult
    public func deleteContext(_ contextId: String) async -> DeleteContextResponseData? {
        await withAdmin { try await $0.deleteContext(contextId, request: nil) }
    }

    /// Join an open subgroup yourself.
    @discardableResult
    public func joinSubgroupInheritance(_ groupId: String) async -> JoinSubgroupInheritanceResponseData? {
        await withAdmin { try await $0.joinSubgroupInheritance(groupId) }
    }

    /// Operator recovery: a full state re-pull for a context stranded mid-sync.
    @discardableResult
    public func resyncContext(
        _ contextId: String, request: ResyncContextRequest = ResyncContextRequest()
    ) async -> ResyncContextResponseData? {
        guard client?.admin != nil, let read = client?.readAdmin else { return nil }
        return await attempt { try await read.resyncContext(contextId, request: request) }
    }
}

/// Joins, which a caller often branches on: with `throwOnError` they rethrow.
/// (== mero-react `useJoinContext`, `useJoinNamespace`, `useRedeemInvitation`.)
@MainActor
public final class JoinActions: MeroMutation {
    /// What the last ``redeem(_:invitation:groupName:teamName:)`` came to.
    @Published public private(set) var outcome: RedeemOutcome?

    @discardableResult
    public func joinContext(_ contextId: String) async throws -> JoinContextResponseData? {
        guard let admin else { return nil }
        return try await run { try await admin.joinContext(contextId) }
    }

    @discardableResult
    public func joinNamespace(
        _ namespaceId: String, request: JoinNamespaceRequest
    ) async throws -> JoinNamespaceResponseData? {
        guard let admin else { return nil }
        return try await run { try await admin.joinNamespace(namespaceId, request: request) }
    }

    /// Follow an invitation: join once, then check membership. A join whose
    /// request failed but which landed anyway is `alreadyMember`, not a
    /// failure. `nil` only with no client to send it through.
    @discardableResult
    public func redeem(
        _ namespaceId: String, invitation: SignedGroupOpenInvitation, groupName: String? = nil,
        teamName: String? = nil
    ) async -> RedeemOutcome? {
        guard let admin else { return nil }
        isLoading = true
        outcome = nil
        defer { isLoading = false }
        let result = await admin.redeemInvitation(
            namespaceId, invitation: invitation, groupName: groupName, teamName: teamName)
        outcome = result
        return result
    }
}

/// Group writes. (== mero-react `useDeleteGroup`, `useSyncGroup`,
/// `useAddGroupMembers`, `useRemoveGroupMembers`, `useUpdateMemberRole`,
/// `useSetDefaultCapabilities`, `useSetSubgroupVisibility`,
/// `useSetTeeAdmissionPolicy`, `useReparentGroup`,
/// `useDetachContextFromGroup`, `useGroupInvitations`, `useJoinGroup`.)
@MainActor
public final class GroupActions: MeroMutation {
    @discardableResult
    public func deleteGroup(_ groupId: String) async -> DeleteGroupResponseData? {
        await withAdmin { try await $0.deleteGroup(groupId, request: nil) }
    }

    @discardableResult
    public func syncGroup(_ groupId: String) async -> SyncGroupResponseData? {
        await withAdmin { try await $0.syncGroup(groupId, request: nil) }
    }

    /// Takes the invitee's signing KEY — the one member call that does.
    @discardableResult
    public func addGroupMembers(_ groupId: String, request: AddGroupMembersRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.addGroupMembers(groupId, request: request)
            return true
        }
    }

    /// Takes the members' ACCOUNTS (not signing keys).
    @discardableResult
    public func removeGroupMembers(_ groupId: String, request: RemoveGroupMembersRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.removeGroupMembers(groupId, request: request)
            return true
        }
    }

    /// `identity` is the member's ACCOUNT.
    @discardableResult
    public func updateMemberRole(_ groupId: String, identity: String, request: UpdateMemberRoleRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.updateMemberRole(groupId, identity: identity, request: request)
            return true
        }
    }

    @discardableResult
    public func setDefaultCapabilities(_ groupId: String, request: SetDefaultCapabilitiesRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.setDefaultCapabilities(groupId, request: request)
            return true
        }
    }

    @discardableResult
    public func setSubgroupVisibility(_ groupId: String, request: SetSubgroupVisibilityRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.setSubgroupVisibility(groupId, request: request)
            return true
        }
    }

    @discardableResult
    public func setTeeAdmissionPolicy(_ groupId: String, request: SetTeeAdmissionPolicyRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.setTeeAdmissionPolicy(groupId, request: request)
            return true
        }
    }

    /// Move `childGroupId` under a new parent.
    @discardableResult
    public func reparentGroup(
        _ childGroupId: String, request: ReparentGroupRequest
    ) async -> ReparentGroupResponseData? {
        await withAdmin { try await $0.reparentGroup(childGroupId, request: request) }
    }

    @discardableResult
    public func detachContextFromGroup(_ groupId: String, contextId: String) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.detachContextFromGroup(groupId, contextId: contextId, request: nil)
            return true
        }
    }

    /// A legacy group invitation.
    @discardableResult
    public func createGroupInvitation(
        _ groupId: String, request: CreateGroupInvitationRequest? = nil
    ) async -> CreateGroupInvitationResult? {
        await withAdmin { try await $0.createGroupInvitation(groupId, request: request) }
    }

    /// Redeem a legacy group invitation.
    @discardableResult
    public func joinGroup(_ request: JoinGroupRequest) async -> JoinGroupResponseData? {
        await withAdmin { try await $0.joinGroup(request) }
    }
}

/// Metadata writes: each replaces the whole record. (== mero-react
/// `useSetGroupMetadata`, `useSetMemberMetadata`, `useSetContextMetadata`.)
@MainActor
public final class MetadataActions: MeroMutation {
    @discardableResult
    public func setGroupMetadata(_ groupId: String, request: SetMetadataRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.setGroupMetadata(groupId, request: request)
            return true
        }
    }

    /// `identity` is the member's ACCOUNT.
    @discardableResult
    public func setMemberMetadata(_ groupId: String, identity: String, request: SetMetadataRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.setMemberMetadata(groupId, identity: identity, request: request)
            return true
        }
    }

    @discardableResult
    public func setContextMetadata(_ groupId: String, contextId: String, request: SetMetadataRequest) async -> Bool? {
        await withAdmin { admin -> Bool in
            try await admin.setContextMetadata(groupId, contextId: contextId, request: request)
            return true
        }
    }
}

/// Namespace writes. (== mero-react `useCreateNamespace`, `useDeleteNamespace`,
/// `useCreateNamespaceInvitation`, `useCreateGroupInNamespace`.)
@MainActor
public final class NamespaceActions: MeroMutation {
    @discardableResult
    public func createNamespace(_ request: CreateNamespaceRequest) async -> CreateNamespaceResponseData? {
        await withAdmin { try await $0.createNamespace(request) }
    }

    @discardableResult
    public func deleteNamespace(_ namespaceId: String) async -> DeleteNamespaceResponseData? {
        await withAdmin { try await $0.deleteNamespace(namespaceId, request: nil) }
    }

    @discardableResult
    public func createNamespaceInvitation(
        _ namespaceId: String, request: CreateNamespaceInvitationRequest? = nil
    ) async -> CreateNamespaceInvitationResult? {
        await withAdmin { try await $0.createNamespaceInvitation(namespaceId, request: request) }
    }

    @discardableResult
    public func createGroupInNamespace(
        _ namespaceId: String, request: CreateGroupInNamespaceRequest? = nil
    ) async -> CreateGroupInNamespaceResponseData? {
        await withAdmin { try await $0.createGroupInNamespace(namespaceId, request: request) }
    }

    /// Set what the namespace approves for an app's publisher to exactly
    /// `request.approve`; an empty list revokes. A node's own: an account is
    /// refused by name.
    @discardableResult
    public func setOutboundApproval(
        _ namespaceId: String, request: SetOutboundApprovalRequest
    ) async -> SetOutboundApprovalResponseData? {
        await withAdmin { try await $0.setOutboundApproval(namespaceId, request: request) }
    }
}

/// Upgrades. (== mero-react `useUpgradeGroup`, `useRetryGroupUpgrade`,
/// `useInstallFromRegistry`.) A node's own: an account is refused by name.
@MainActor
public final class UpgradeActions: MeroMutation {
    @discardableResult
    public func upgradeGroup(_ groupId: String, request: UpgradeGroupRequest) async -> UpgradeGroupResponseData? {
        await withAdmin { try await $0.upgradeGroup(groupId, request: request) }
    }

    @discardableResult
    public func retryGroupUpgrade(_ groupId: String) async -> RetryGroupUpgradeResponseData? {
        await withAdmin { try await $0.retryGroupUpgrade(groupId, request: nil) }
    }

    /// Install `package@version` onto the node — the "Download" step before an
    /// upgrade. The node resolves it against its own registry.
    @discardableResult
    public func installFromRegistry(_ packageName: String, version: String) async -> InstallApplicationResponseData? {
        await withAdmin {
            try await $0.installApplication(InstallApplicationRequest(package: packageName, version: version))
        }
    }
}

/// Blob uploads. (== mero-react `useUploadBlob`.) Pass `contextId` in the
/// request to announce the blob to that context's members.
@MainActor
public final class BlobActions: MeroMutation {
    @discardableResult
    public func uploadBlob(_ request: UploadBlobRequest) async -> UploadBlobResponseData? {
        guard client?.admin != nil, let read = client?.readAdmin else { return nil }
        return await attempt { try await read.uploadBlob(request) }
    }
}

/// A member's capability bits, readable and settable — one state for both.
/// `memberId` is the member's ACCOUNT. (== mero-react `useGroupCapabilities`.)
@MainActor
public final class GroupCapabilities: ObservableObject {
    @Published public private(set) var capabilities: Int?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    private weak var client: MeroClient?
    public let groupId: String?
    public let memberId: String?
    private var sequence = 0

    public init(client: MeroClient, groupId: String?, memberId: String?, autoload: Bool = true) {
        self.client = client
        self.groupId = groupId
        self.memberId = memberId
        if autoload { Task { [weak self] in await self?.refetch() } }
    }

    @discardableResult
    public func refetch() async -> Int? {
        sequence += 1
        let seq = sequence
        guard let admin = client?.admin, let groupId, let memberId else {
            capabilities = nil
            error = nil
            isLoading = false
            return nil
        }
        isLoading = true
        error = nil
        defer { if seq == sequence { isLoading = false } }
        do {
            let value = try await admin.getMemberCapabilities(groupId, identity: memberId).capabilities
            if seq == sequence { capabilities = value }
            return value
        } catch {
            if seq == sequence { self.error = error }
            return nil
        }
    }

    @discardableResult
    public func setCapabilities(_ next: Int) async -> Int? {
        guard let admin = client?.admin, let groupId, let memberId else { return nil }
        sequence += 1
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await admin.setMemberCapabilities(
                groupId, identity: memberId, request: SetMemberCapabilitiesRequest(capabilities: next))
            capabilities = next
            return next
        } catch {
            self.error = error
            return nil
        }
    }
}
