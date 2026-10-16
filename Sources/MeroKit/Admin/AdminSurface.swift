import Foundation

// One admin surface for a node and for an account. Port of the shape mero-js
// gets from a `Proxy` over `AdminApiClient` (`account/account-admin.ts`,
// `account/node-admin.ts`): Swift has no proxies, so the surface an app codes
// against is this protocol, which ``AdminApi`` conforms to as it ships, and so
// do ``AccountAdmin`` (an account's admin through its relays) and
// ``NodeAdmin`` (a node's, with `createNamespace` installing the app first).
//
// Requirements carry no default arguments (a protocol cannot); each concrete
// type keeps its own defaults, so `admin.createGroupInNamespace(ns)` still
// reads the same on an ``AdminApi``.

/// The admin calls an app makes, on a node or as an account.
///
/// Everything an app needs to list, create, join, invite and govern is here,
/// with ``AdminApi``'s exact names and types, so code written against a node's
/// admin runs unchanged against an account's. The node-only calls are here
/// too, so an account can refuse them by name
/// (``AccountError/notForAccount(method:)``) rather than with a bare `403`.
/// Calls outside this surface stay on ``AdminApi``.
public protocol AdminSurface: Sendable {
    // MARK: Identity and applications

    func getNodeIdentity() async throws -> NodeIdentity
    func listApplications() async throws -> ListApplicationsResponseData
    func getApplication(_ appId: String) async throws -> GetApplicationResponseData

    // MARK: Contexts

    func getContexts() async throws -> GetContextsResponseData
    func getContext(_ contextId: String) async throws -> Context
    func getContextGroup(_ contextId: String) async throws -> ContextGroupResponseData
    func getContextIdentities(_ contextId: String) async throws -> GetContextIdentitiesResponseData
    func getContextIdentitiesOwned(_ contextId: String) async throws -> GetContextIdentitiesResponseData
    func queryContext(_ contextId: String, request: QueryContextRequest) async throws -> QueryContextResponseData

    // MARK: Namespaces and groups, reads

    func listNamespaces() async throws -> ListNamespacesResponseData
    func getNamespace(_ namespaceId: String) async throws -> Namespace
    func listNamespacesForApplication(_ applicationId: String) async throws -> ListNamespacesResponseData
    func listNamespaceGroups(_ namespaceId: String) async throws -> [SubgroupEntry]
    func getGroupInfo(_ groupId: String) async throws -> GroupInfoResponseData
    func getDefaultCapabilities(_ groupId: String) async throws -> Int
    func getSubgroupVisibility(_ groupId: String) async throws -> String
    func listGroupMembers(_ groupId: String) async throws -> ListGroupMembersResponseData
    func listGroupContexts(_ groupId: String) async throws -> ListGroupContextsResponseData
    func listSubgroups(_ groupId: String) async throws -> [SubgroupEntry]
    func getMemberCapabilities(_ groupId: String, identity: String) async throws -> MemberCapabilities
    func getGroupMetadata(_ groupId: String) async throws -> MetadataRecord?
    func getMemberMetadata(_ groupId: String, identity: String) async throws -> MetadataRecord?
    func getContextMetadata(_ groupId: String, contextId: String) async throws -> MetadataRecord?
    func getGroupUpgradeStatus(_ groupId: String) async throws -> GroupUpgradeStatusResponseData
    func getMigrationStatus(_ namespaceId: String) async throws -> MigrationStatus
    func getCascadeStatus(_ namespaceId: String) async throws -> [CascadeStatusEntry]

    // MARK: Namespaces and groups, writes

    func createNamespace(_ request: CreateNamespaceRequest) async throws -> CreateNamespaceResponseData
    func createGroupInNamespace(
        _ namespaceId: String, request: CreateGroupInNamespaceRequest?
    ) async throws -> CreateGroupInNamespaceResponseData
    func addGroupMembers(_ groupId: String, request: AddGroupMembersRequest) async throws
    func removeGroupMembers(_ groupId: String, request: RemoveGroupMembersRequest) async throws
    func setGroupMetadata(_ groupId: String, request: SetGroupMetadataRequest) async throws
    func setMemberMetadata(_ groupId: String, identity: String, request: SetMemberMetadataRequest) async throws
    func setContextMetadata(_ groupId: String, contextId: String, request: SetContextMetadataRequest) async throws
    func setDefaultCapabilities(_ groupId: String, request: SetDefaultCapabilitiesRequest) async throws
    func setSubgroupVisibility(_ groupId: String, request: SetSubgroupVisibilityRequest) async throws
    func setMemberCapabilities(_ groupId: String, identity: String, request: SetMemberCapabilitiesRequest) async throws
    func updateMemberRole(_ groupId: String, identity: String, request: UpdateMemberRoleRequest) async throws
    func deleteGroup(_ groupId: String, request: DeleteGroupRequest?) async throws -> DeleteGroupResponseData
    func reparentGroup(_ childGroupId: String, request: ReparentGroupRequest) async throws -> ReparentGroupResponseData
    func leaveGroup(_ groupId: String, request: [String: JSONValue]?) async throws
    func leaveNamespace(_ namespaceId: String, request: [String: JSONValue]?) async throws

    // MARK: Joining, creating and inviting

    func joinContext(_ contextId: String) async throws -> JoinContextResponseData
    func createContext(_ request: CreateContextRequest) async throws -> CreateContextResponseData
    func createNamespaceInvitation(
        _ namespaceId: String, request: CreateNamespaceInvitationRequest?
    ) async throws -> CreateNamespaceInvitationResult
    func joinNamespace(_ namespaceId: String, request: JoinNamespaceRequest) async throws -> JoinNamespaceResponseData
    func joinSubgroupInheritance(_ groupId: String) async throws -> JoinSubgroupInheritanceResponseData
    func detachContextFromGroup(
        _ groupId: String, contextId: String, request: DetachContextFromGroupRequest?
    ) async throws
    func syncGroup(_ groupId: String, request: SyncGroupRequest?) async throws -> SyncGroupResponseData
    func syncContext(_ contextId: String?) async throws

    // MARK: A node's own, refused for an account

    func upgradeGroup(_ groupId: String, request: UpgradeGroupRequest) async throws -> UpgradeGroupResponseData
    func retryGroupUpgrade(
        _ groupId: String, request: RetryGroupUpgradeRequest?
    ) async throws -> RetryGroupUpgradeResponseData
    func abortMigration(_ namespaceId: String, request: [String: JSONValue]?) async throws -> JSONValue
    func installApplication(_ request: InstallApplicationRequest) async throws -> InstallApplicationResponseData
    func installDevApplication(_ request: InstallDevApplicationRequest) async throws -> InstallApplicationResponseData
    func uninstallApplication(_ appId: String) async throws -> UninstallApplicationResponseData
    func generateContextIdentity() async throws -> GenerateContextIdentityResponseData
    func deleteContext(_ contextId: String, request: DeleteContextRequest?) async throws -> DeleteContextResponseData
    func leaveContext(_ contextId: String, request: [String: JSONValue]?) async throws
    func createContextAlias(_ request: CreateContextAliasRequest) async throws -> CreateAliasResponseData
    func createApplicationAlias(_ request: CreateApplicationAliasRequest) async throws -> CreateAliasResponseData
    func createDeviceAlias(_ request: CreateDeviceAliasRequest) async throws -> CreateAliasResponseData
    func deleteContextAlias(_ name: String) async throws -> DeleteAliasResponseData
    func deleteApplicationAlias(_ name: String) async throws -> DeleteAliasResponseData
    func deleteDeviceAlias(_ name: String) async throws -> DeleteAliasResponseData
    func lookupContextAlias(_ name: String) async throws -> LookupAliasResponseData
    func lookupApplicationAlias(_ name: String) async throws -> LookupAliasResponseData
    func lookupDeviceAlias(_ name: String) async throws -> LookupAliasResponseData
    func listContextAliases() async throws -> ListAliasesResponseData
    func listApplicationAliases() async throws -> ListAliasesResponseData
    func listDeviceAliases() async throws -> ListAliasesResponseData
    func deleteNamespace(
        _ namespaceId: String, request: DeleteNamespaceRequest?
    ) async throws -> DeleteNamespaceResponseData
    func createGroupInvitation(
        _ groupId: String, request: CreateGroupInvitationRequest?
    ) async throws -> CreateGroupInvitationResult
    func joinGroup(_ request: JoinGroupRequest) async throws -> JoinGroupResponseData
    func setTeeAdmissionPolicy(_ groupId: String, request: SetTeeAdmissionPolicyRequest) async throws
    func getTeeAdmissionPolicy(_ groupId: String) async throws -> GetTeeAdmissionPolicyResponseData
    func deleteBlob(_ blobId: String) async throws -> DeleteBlobResponseData
    func listAccountDevices() async throws -> [AccountDeviceEntry]
    func revokeDevice(_ namespaceId: String, request: RevokeDeviceRequest) async throws -> RevokeDeviceResponseData
}

extension AdminApi: AdminSurface {}

/// An ``AdminSurface`` that forwards every call to an ``AdminApi``, so a type
/// overrides only what it changes (``NodeAdmin`` overrides `createNamespace`).
public protocol AdminApiForwarding: AdminSurface {
    /// Where calls go; throwing when there is nowhere to send them.
    var forwardedAdmin: AdminApi { get throws }
}

public extension AdminApiForwarding {
    // MARK: Identity and applications

    func getNodeIdentity() async throws -> NodeIdentity {
        try await forwardedAdmin.getNodeIdentity()
    }

    func listApplications() async throws -> ListApplicationsResponseData {
        try await forwardedAdmin.listApplications()
    }

    func getApplication(_ appId: String) async throws -> GetApplicationResponseData {
        try await forwardedAdmin.getApplication(appId)
    }

    // MARK: Contexts

    func getContexts() async throws -> GetContextsResponseData {
        try await forwardedAdmin.getContexts()
    }

    func getContext(_ contextId: String) async throws -> Context {
        try await forwardedAdmin.getContext(contextId)
    }

    func getContextGroup(_ contextId: String) async throws -> ContextGroupResponseData {
        try await forwardedAdmin.getContextGroup(contextId)
    }

    func getContextIdentities(_ contextId: String) async throws -> GetContextIdentitiesResponseData {
        try await forwardedAdmin.getContextIdentities(contextId)
    }

    func getContextIdentitiesOwned(_ contextId: String) async throws -> GetContextIdentitiesResponseData {
        try await forwardedAdmin.getContextIdentitiesOwned(contextId)
    }

    func queryContext(_ contextId: String, request: QueryContextRequest) async throws -> QueryContextResponseData {
        try await forwardedAdmin.queryContext(contextId, request: request)
    }

    // MARK: Namespaces and groups, reads

    func listNamespaces() async throws -> ListNamespacesResponseData {
        try await forwardedAdmin.listNamespaces()
    }

    func getNamespace(_ namespaceId: String) async throws -> Namespace {
        try await forwardedAdmin.getNamespace(namespaceId)
    }

    func listNamespacesForApplication(_ applicationId: String) async throws -> ListNamespacesResponseData {
        try await forwardedAdmin.listNamespacesForApplication(applicationId)
    }

    func listNamespaceGroups(_ namespaceId: String) async throws -> [SubgroupEntry] {
        try await forwardedAdmin.listNamespaceGroups(namespaceId)
    }

    func getGroupInfo(_ groupId: String) async throws -> GroupInfoResponseData {
        try await forwardedAdmin.getGroupInfo(groupId)
    }

    func getDefaultCapabilities(_ groupId: String) async throws -> Int {
        try await forwardedAdmin.getDefaultCapabilities(groupId)
    }

    func getSubgroupVisibility(_ groupId: String) async throws -> String {
        try await forwardedAdmin.getSubgroupVisibility(groupId)
    }

    func listGroupMembers(_ groupId: String) async throws -> ListGroupMembersResponseData {
        try await forwardedAdmin.listGroupMembers(groupId)
    }

    func listGroupContexts(_ groupId: String) async throws -> ListGroupContextsResponseData {
        try await forwardedAdmin.listGroupContexts(groupId)
    }

    func listSubgroups(_ groupId: String) async throws -> [SubgroupEntry] {
        try await forwardedAdmin.listSubgroups(groupId)
    }

    func getMemberCapabilities(_ groupId: String, identity: String) async throws -> MemberCapabilities {
        try await forwardedAdmin.getMemberCapabilities(groupId, identity: identity)
    }

    func getGroupMetadata(_ groupId: String) async throws -> MetadataRecord? {
        try await forwardedAdmin.getGroupMetadata(groupId)
    }

    func getMemberMetadata(_ groupId: String, identity: String) async throws -> MetadataRecord? {
        try await forwardedAdmin.getMemberMetadata(groupId, identity: identity)
    }

    func getContextMetadata(_ groupId: String, contextId: String) async throws -> MetadataRecord? {
        try await forwardedAdmin.getContextMetadata(groupId, contextId: contextId)
    }

    func getGroupUpgradeStatus(_ groupId: String) async throws -> GroupUpgradeStatusResponseData {
        try await forwardedAdmin.getGroupUpgradeStatus(groupId)
    }

    func getMigrationStatus(_ namespaceId: String) async throws -> MigrationStatus {
        try await forwardedAdmin.getMigrationStatus(namespaceId)
    }

    func getCascadeStatus(_ namespaceId: String) async throws -> [CascadeStatusEntry] {
        try await forwardedAdmin.getCascadeStatus(namespaceId)
    }

    // MARK: Namespaces and groups, writes

    func createNamespace(_ request: CreateNamespaceRequest) async throws -> CreateNamespaceResponseData {
        try await forwardedAdmin.createNamespace(request)
    }

    func createGroupInNamespace(
        _ namespaceId: String, request: CreateGroupInNamespaceRequest?
    ) async throws -> CreateGroupInNamespaceResponseData {
        try await forwardedAdmin.createGroupInNamespace(namespaceId, request: request)
    }

    func addGroupMembers(_ groupId: String, request: AddGroupMembersRequest) async throws {
        try await forwardedAdmin.addGroupMembers(groupId, request: request)
    }

    func removeGroupMembers(_ groupId: String, request: RemoveGroupMembersRequest) async throws {
        try await forwardedAdmin.removeGroupMembers(groupId, request: request)
    }

    func setGroupMetadata(_ groupId: String, request: SetGroupMetadataRequest) async throws {
        try await forwardedAdmin.setGroupMetadata(groupId, request: request)
    }

    func setMemberMetadata(_ groupId: String, identity: String, request: SetMemberMetadataRequest) async throws {
        try await forwardedAdmin.setMemberMetadata(groupId, identity: identity, request: request)
    }

    func setContextMetadata(_ groupId: String, contextId: String, request: SetContextMetadataRequest) async throws {
        try await forwardedAdmin.setContextMetadata(groupId, contextId: contextId, request: request)
    }

    func setDefaultCapabilities(_ groupId: String, request: SetDefaultCapabilitiesRequest) async throws {
        try await forwardedAdmin.setDefaultCapabilities(groupId, request: request)
    }

    func setSubgroupVisibility(_ groupId: String, request: SetSubgroupVisibilityRequest) async throws {
        try await forwardedAdmin.setSubgroupVisibility(groupId, request: request)
    }

    func setMemberCapabilities(
        _ groupId: String, identity: String, request: SetMemberCapabilitiesRequest
    ) async throws {
        try await forwardedAdmin.setMemberCapabilities(groupId, identity: identity, request: request)
    }

    func updateMemberRole(_ groupId: String, identity: String, request: UpdateMemberRoleRequest) async throws {
        try await forwardedAdmin.updateMemberRole(groupId, identity: identity, request: request)
    }

    func deleteGroup(_ groupId: String, request: DeleteGroupRequest?) async throws -> DeleteGroupResponseData {
        try await forwardedAdmin.deleteGroup(groupId, request: request)
    }

    func reparentGroup(
        _ childGroupId: String, request: ReparentGroupRequest
    ) async throws -> ReparentGroupResponseData {
        try await forwardedAdmin.reparentGroup(childGroupId, request: request)
    }

    func leaveGroup(_ groupId: String, request: [String: JSONValue]?) async throws {
        try await forwardedAdmin.leaveGroup(groupId, request: request)
    }

    func leaveNamespace(_ namespaceId: String, request: [String: JSONValue]?) async throws {
        try await forwardedAdmin.leaveNamespace(namespaceId, request: request)
    }

    // MARK: Joining, creating and inviting

    func joinContext(_ contextId: String) async throws -> JoinContextResponseData {
        try await forwardedAdmin.joinContext(contextId)
    }

    func createContext(_ request: CreateContextRequest) async throws -> CreateContextResponseData {
        try await forwardedAdmin.createContext(request)
    }

    func createNamespaceInvitation(
        _ namespaceId: String, request: CreateNamespaceInvitationRequest?
    ) async throws -> CreateNamespaceInvitationResult {
        try await forwardedAdmin.createNamespaceInvitation(namespaceId, request: request)
    }

    func joinNamespace(_ namespaceId: String, request: JoinNamespaceRequest) async throws -> JoinNamespaceResponseData {
        try await forwardedAdmin.joinNamespace(namespaceId, request: request)
    }

    func joinSubgroupInheritance(_ groupId: String) async throws -> JoinSubgroupInheritanceResponseData {
        try await forwardedAdmin.joinSubgroupInheritance(groupId)
    }

    func detachContextFromGroup(
        _ groupId: String, contextId: String, request: DetachContextFromGroupRequest?
    ) async throws {
        try await forwardedAdmin.detachContextFromGroup(groupId, contextId: contextId, request: request)
    }

    func syncGroup(_ groupId: String, request: SyncGroupRequest?) async throws -> SyncGroupResponseData {
        try await forwardedAdmin.syncGroup(groupId, request: request)
    }

    func syncContext(_ contextId: String?) async throws {
        try await forwardedAdmin.syncContext(contextId)
    }

    // MARK: A node's own, refused for an account

    func upgradeGroup(_ groupId: String, request: UpgradeGroupRequest) async throws -> UpgradeGroupResponseData {
        try await forwardedAdmin.upgradeGroup(groupId, request: request)
    }

    func retryGroupUpgrade(
        _ groupId: String, request: RetryGroupUpgradeRequest?
    ) async throws -> RetryGroupUpgradeResponseData {
        try await forwardedAdmin.retryGroupUpgrade(groupId, request: request)
    }

    func abortMigration(_ namespaceId: String, request: [String: JSONValue]?) async throws -> JSONValue {
        try await forwardedAdmin.abortMigration(namespaceId, request: request)
    }

    func installApplication(_ request: InstallApplicationRequest) async throws -> InstallApplicationResponseData {
        try await forwardedAdmin.installApplication(request)
    }

    func installDevApplication(_ request: InstallDevApplicationRequest) async throws -> InstallApplicationResponseData {
        try await forwardedAdmin.installDevApplication(request)
    }

    func uninstallApplication(_ appId: String) async throws -> UninstallApplicationResponseData {
        try await forwardedAdmin.uninstallApplication(appId)
    }

    func generateContextIdentity() async throws -> GenerateContextIdentityResponseData {
        try await forwardedAdmin.generateContextIdentity()
    }

    func deleteContext(_ contextId: String, request: DeleteContextRequest?) async throws -> DeleteContextResponseData {
        try await forwardedAdmin.deleteContext(contextId, request: request)
    }

    func leaveContext(_ contextId: String, request: [String: JSONValue]?) async throws {
        try await forwardedAdmin.leaveContext(contextId, request: request)
    }

    func createContextAlias(_ request: CreateContextAliasRequest) async throws -> CreateAliasResponseData {
        try await forwardedAdmin.createContextAlias(request)
    }

    func createApplicationAlias(_ request: CreateApplicationAliasRequest) async throws -> CreateAliasResponseData {
        try await forwardedAdmin.createApplicationAlias(request)
    }

    func createDeviceAlias(_ request: CreateDeviceAliasRequest) async throws -> CreateAliasResponseData {
        try await forwardedAdmin.createDeviceAlias(request)
    }

    func deleteContextAlias(_ name: String) async throws -> DeleteAliasResponseData {
        try await forwardedAdmin.deleteContextAlias(name)
    }

    func deleteApplicationAlias(_ name: String) async throws -> DeleteAliasResponseData {
        try await forwardedAdmin.deleteApplicationAlias(name)
    }

    func deleteDeviceAlias(_ name: String) async throws -> DeleteAliasResponseData {
        try await forwardedAdmin.deleteDeviceAlias(name)
    }

    func lookupContextAlias(_ name: String) async throws -> LookupAliasResponseData {
        try await forwardedAdmin.lookupContextAlias(name)
    }

    func lookupApplicationAlias(_ name: String) async throws -> LookupAliasResponseData {
        try await forwardedAdmin.lookupApplicationAlias(name)
    }

    func lookupDeviceAlias(_ name: String) async throws -> LookupAliasResponseData {
        try await forwardedAdmin.lookupDeviceAlias(name)
    }

    func listContextAliases() async throws -> ListAliasesResponseData {
        try await forwardedAdmin.listContextAliases()
    }

    func listApplicationAliases() async throws -> ListAliasesResponseData {
        try await forwardedAdmin.listApplicationAliases()
    }

    func listDeviceAliases() async throws -> ListAliasesResponseData {
        try await forwardedAdmin.listDeviceAliases()
    }

    func deleteNamespace(
        _ namespaceId: String, request: DeleteNamespaceRequest?
    ) async throws -> DeleteNamespaceResponseData {
        try await forwardedAdmin.deleteNamespace(namespaceId, request: request)
    }

    func createGroupInvitation(
        _ groupId: String, request: CreateGroupInvitationRequest?
    ) async throws -> CreateGroupInvitationResult {
        try await forwardedAdmin.createGroupInvitation(groupId, request: request)
    }

    func joinGroup(_ request: JoinGroupRequest) async throws -> JoinGroupResponseData {
        try await forwardedAdmin.joinGroup(request)
    }

    func setTeeAdmissionPolicy(_ groupId: String, request: SetTeeAdmissionPolicyRequest) async throws {
        try await forwardedAdmin.setTeeAdmissionPolicy(groupId, request: request)
    }

    func getTeeAdmissionPolicy(_ groupId: String) async throws -> GetTeeAdmissionPolicyResponseData {
        try await forwardedAdmin.getTeeAdmissionPolicy(groupId)
    }

    func deleteBlob(_ blobId: String) async throws -> DeleteBlobResponseData {
        try await forwardedAdmin.deleteBlob(blobId)
    }

    func listAccountDevices() async throws -> [AccountDeviceEntry] {
        try await forwardedAdmin.listAccountDevices()
    }

    func revokeDevice(_ namespaceId: String, request: RevokeDeviceRequest) async throws -> RevokeDeviceResponseData {
        try await forwardedAdmin.revokeDevice(namespaceId, request: request)
    }
}
