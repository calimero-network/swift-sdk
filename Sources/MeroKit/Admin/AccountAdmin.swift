import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// An account's admin API: ``AdminApi``'s names and types, so an app written
// against a node's admin needs no second code path. Port of mero-js
// `src/account/account-admin.ts` and `node-admin.ts`.
//
// Reads go to the relay's caller-scoped admin (``MeroTransportClient/admin``
// of a delegated client); writes go through the relay as governance ops,
// delegated context and namespace creation, or an invitation the account
// signs itself. A call with no account form is refused by name.

/// The app an admin founds namespaces for: its registry package, and the
/// version to pin (the registry's latest when `nil`).
public struct AdminAppConfig: Sendable, Equatable {
    public var packageName: String?
    public var packageVersion: String?
    /// The registry the package is published on (``ApplicationRegistry/defaultURL``).
    public var registryURL: String?

    public init(packageName: String? = nil, packageVersion: String? = nil, registryURL: String? = nil) {
        self.packageName = packageName
        self.packageVersion = packageVersion
        self.registryURL = registryURL
    }

    var registry: String { registryURL ?? ApplicationRegistry.defaultURL }
}

/// What an account signs an invitation from (``GroupInvitations/sign(groupId:inviterAccount:keys:admitters:members:invitedRole:validForSeconds:now:nonce:applicationId:appKey:admitterAddrs:)``).
public struct AccountInvitationInput: Sendable {
    public var groupId: String
    public var inviterAccount: String
    public var keys: DeviceKeys
    /// The namespace's relays; empty to default to its admins.
    public var admitters: [String]
    public var members: [GroupMember]
    public var applicationId: String?
    public var appKey: String?
    public var invitedRole: GroupInvitations.InvitedRole
    public var validForSeconds: Int
}

/// What ``AccountAdmin`` does its writes with. ``live(_:)`` is the real thing;
/// tests substitute any of them. (== mero-js `AccountAdminDeps`.)
public struct AccountAdminDeps: Sendable {
    /// `(session, groupId, op) → groupId`.
    public typealias Govern = @Sendable (DelegatedSession, String, Warrants.GovernanceOp) async throws -> String
    public typealias CreateContext =
        @Sendable (DelegatedSession, CreateDelegatedContextRequest) async throws -> CreatedRelayContext
    /// `(session, defaultCapabilities, application) → founded`.
    public typealias Found =
        @Sendable (DelegatedSession, UInt32?, FoundingApplication?) async throws -> FoundedDelegatedNamespace
    /// `(registryURL, package) → version`.
    public typealias LatestVersion = @Sendable (String, String) async throws -> String
    public typealias SignInvitation = @Sendable (AccountInvitationInput) throws -> SignedGroupOpenInvitation
    /// `(namespaceId, invitation) → namespaceId`.
    public typealias Join = @Sendable (String, SignedGroupOpenInvitation) async throws -> String
    /// `namespaceId → the accounts of the nodes the cloud routes it to`.
    public typealias Routing = @Sendable (String) async throws -> [String?]

    /// A group op on a group (``DelegatedAccounts/governGroup(_:groupId:op:env:)``).
    public var governGroup: Govern
    /// A root op, posted to the group's namespace (``DelegatedAccounts/governRoot(_:groupId:op:env:)``).
    public var governRoot: Govern
    public var createContext: CreateContext
    /// Found a namespace with a default capability mask and an application.
    public var found: Found
    public var latestVersion: LatestVersion
    public var signInvitation: SignInvitation
    /// Redeem an invitation for this account and switch the session onto the
    /// relay that admitted it (``DelegatedAccounts/joinAsAccount(_:namespaceId:invitation:cloudBaseURL:env:onJoined:)``).
    /// The provider of the session supplies it; without it a join is refused by name.
    public var join: Join?
    /// The cloud's routing (``CloudClient/getNamespaceRouting(_:)``). Given,
    /// an invitation is minted only if one of the routed nodes is an admitter
    /// it names.
    public var routing: Routing?

    public init(
        governGroup: @escaping Govern, governRoot: @escaping Govern, createContext: @escaping CreateContext,
        found: @escaping Found, latestVersion: @escaping LatestVersion, signInvitation: @escaping SignInvitation,
        join: Join? = nil, routing: Routing? = nil
    ) {
        self.governGroup = governGroup
        self.governRoot = governRoot
        self.createContext = createContext
        self.found = found
        self.latestVersion = latestVersion
        self.signInvitation = signInvitation
        self.join = join
        self.routing = routing
    }

    /// The real governance, creation, founding, registry and signing, in `env`.
    public static func live(_ env: DelegatedEnvironment) -> AccountAdminDeps {
        AccountAdminDeps(
            governGroup: { session, groupId, op in
                try await DelegatedAccounts.governGroup(session, groupId: groupId, op: op, env: env)
            },
            governRoot: { session, groupId, op in
                try await DelegatedAccounts.governRoot(session, groupId: groupId, op: op, env: env)
            },
            createContext: { session, request in
                try await DelegatedAccounts.createDelegatedContext(session, request, env: env)
            },
            found: { session, capabilities, application in
                try await DelegatedAccounts.foundDelegatedNamespace(
                    session, defaultCapabilities: capabilities, application: application, env: env)
            },
            latestVersion: { registry, package in
                try await DelegatedAccounts.latestPublishedVersion(
                    registryURL: registry, package: package, session: env.urlSession)
            },
            signInvitation: { try AccountAdmin.sign($0) })
    }
}

/// An account's admin: an ``AdminSurface`` over the relay's caller-scoped
/// read client, with the writes done as the account. (== mero-js
/// `createAccountAdmin`.)
///
/// - Reads not listed below go to the relay unchanged.
/// - Namespace, member, metadata, settings, group and context writes become
///   governance ops through the namespace's relay; `createNamespace` founds
///   through the relay with this app's package; `createNamespaceInvitation`
///   is signed with the device key; `joinNamespace` runs ``AccountAdminDeps/join``.
/// - Calls with no account form (upgrades, installs, aliases, a node's own
///   copy of a context, TEE policy, legacy group invitations, account devices)
///   throw ``AccountError/notForAccount(method:)`` and send nothing.
/// - With no relay yet (`read == nil`) the account is a member of nothing:
///   `listNamespaces`, `listNamespacesForApplication` and `getContexts` are
///   empty, `getNodeIdentity` and `joinNamespace` work, and everything else
///   throws ``AccountError/noRelay(method:)``.
public struct AccountAdmin: AdminApiForwarding {
    /// The account.
    public let session: DelegatedSession
    /// The relay's admin as the account, or `nil` with no relay yet.
    public let read: AdminApi?
    public let app: AdminAppConfig
    private let store: DelegatedAccountStore
    private let deps: AccountAdminDeps

    /// The mask an account founds a namespace with (mero-react's).
    public static let defaultNamespaceCapabilities: UInt32 = 231

    public init(
        session: DelegatedSession, read: AdminApi?, app: AdminAppConfig = AdminAppConfig(),
        env: DelegatedEnvironment = DelegatedEnvironment(), deps: AccountAdminDeps? = nil
    ) {
        self.session = session
        self.read = read
        self.app = app
        self.store = env.store
        self.deps = deps ?? .live(env)
    }

    /// Reads go to the relay; with none, ``AccountError/noRelay(method:)``.
    public var forwardedAdmin: AdminApi {
        get throws {
            guard let read else { throw AccountError.noRelay(method: "this call") }
            return read
        }
    }

    // MARK: - Identity and listings

    /// The account itself: the relay executes as the account.
    public func getNodeIdentity() async throws -> NodeIdentity {
        NodeIdentity(accountId: session.account, deviceId: nil, publicKey: "", accountRootPublicKey: "")
    }

    public func listNamespaces() async throws -> ListNamespacesResponseData {
        guard let read else { return [] }
        return try await read.listNamespaces()
    }

    /// The node-wide `for-application` listing is not caller-scoped, so a
    /// relay refuses it to an account: its own scoped list, filtered, is the answer.
    public func listNamespacesForApplication(_ applicationId: String) async throws -> ListNamespacesResponseData {
        try await listNamespaces().filter { $0.targetApplicationId == applicationId }
    }

    public func getContexts() async throws -> GetContextsResponseData {
        guard let read else { return GetContextsResponseData(contexts: []) }
        return try await read.getContexts()
    }

    /// An account runs as itself in every context it can reach, so its
    /// identity there is the account — owned once it is a member of the
    /// context's group, as a node's identity is owned once it has joined.
    public func getContextIdentitiesOwned(_ contextId: String) async throws -> GetContextIdentitiesResponseData {
        let member = try await isMemberOfContextGroup(contextId)
        return GetContextIdentitiesResponseData(identities: member ? [session.account] : [])
    }

    // MARK: - Namespaces and groups

    /// Found a namespace through the relay with this app's package (at the
    /// registry's latest version unless pinned), then name it. HA's outcome
    /// rides along in `haEnabled` / `haError`.
    public func createNamespace(_ request: CreateNamespaceRequest) async throws -> CreateNamespaceResponseData {
        try requireRelay("createNamespace")
        guard let package = app.packageName else {
            throw AccountError.notForAccount(method: "createNamespace without a packageName")
        }
        let version: String
        if let pinned = app.packageVersion {
            version = pinned
        } else {
            version = try await deps.latestVersion(app.registry, package)
        }
        let founded = try await deps.found(
            session, Self.defaultNamespaceCapabilities,
            FoundingApplication(applicationId: request.applicationId, package: package, version: version))
        if let name = request.name {
            try await group(founded.namespaceId, GovernanceOps.groupMetadataSet(name: name))
        }
        return CreateNamespaceResponseData(
            namespaceId: founded.namespaceId, haEnabled: founded.haEnabled, haError: founded.haError)
    }

    /// A subgroup, Open unless `visibility` is `"restricted"` (as on a node),
    /// created by a root op on the namespace and remembered as in it.
    public func createGroupInNamespace(
        _ namespaceId: String, request: CreateGroupInNamespaceRequest? = nil
    ) async throws -> CreateGroupInNamespaceResponseData {
        try requireRelay("createGroupInNamespace")
        let creation = try GovernanceOps.subgroupCreation(
            parentId: namespaceId, restricted: request?.visibility == "restricted", admin: session.account)
        let groupId = try await root(namespaceId, creation.op)
        store.rememberGroupNamespace(account: session.account, groupId: groupId, namespaceId: namespaceId)
        if let name = request?.groupName {
            try await group(groupId, GovernanceOps.groupMetadataSet(name: name))
        }
        return CreateGroupInNamespaceResponseData(groupId: groupId)
    }

    public func addGroupMembers(_ groupId: String, request: AddGroupMembersRequest) async throws {
        try requireRelay("addGroupMembers")
        for member in request.members {
            try await group(groupId, GovernanceOps.memberAdded(member.identity, role: try Self.role(member.role)))
        }
    }

    public func removeGroupMembers(_ groupId: String, request: RemoveGroupMembersRequest) async throws {
        try requireRelay("removeGroupMembers")
        for member in request.members {
            try await group(groupId, GovernanceOps.memberRemoved(member))
        }
    }

    public func setGroupMetadata(_ groupId: String, request: SetGroupMetadataRequest) async throws {
        try requireRelay("setGroupMetadata")
        try await group(groupId, GovernanceOps.groupMetadataSet(name: request.name, data: request.data ?? [:]))
    }

    public func setMemberMetadata(_ groupId: String, identity: String, request: SetMemberMetadataRequest) async throws {
        try requireRelay("setMemberMetadata")
        try await group(
            groupId, GovernanceOps.memberMetadataSet(identity, name: request.name, data: request.data ?? [:]))
    }

    public func setContextMetadata(
        _ groupId: String, contextId: String, request: SetContextMetadataRequest
    ) async throws {
        try requireRelay("setContextMetadata")
        try await group(
            groupId, GovernanceOps.contextMetadataSet(contextId, name: request.name, data: request.data ?? [:]))
    }

    public func setDefaultCapabilities(_ groupId: String, request: SetDefaultCapabilitiesRequest) async throws {
        try requireRelay("setDefaultCapabilities")
        try await group(groupId, GovernanceOps.defaultCapabilitiesSet(try Self.mask(request.defaultCapabilities)))
    }

    public func setSubgroupVisibility(_ groupId: String, request: SetSubgroupVisibilityRequest) async throws {
        try requireRelay("setSubgroupVisibility")
        let mode: GovernanceOps.SubgroupVisibility = request.subgroupVisibility == "open" ? .open : .restricted
        try await group(groupId, GovernanceOps.subgroupVisibilitySet(mode))
    }

    public func setMemberCapabilities(
        _ groupId: String, identity: String, request: SetMemberCapabilitiesRequest
    ) async throws {
        try requireRelay("setMemberCapabilities")
        try await group(
            groupId, GovernanceOps.memberCapabilitySet(identity, capabilities: try Self.mask(request.capabilities)))
    }

    public func updateMemberRole(_ groupId: String, identity: String, request: UpdateMemberRoleRequest) async throws {
        try requireRelay("updateMemberRole")
        try await group(groupId, GovernanceOps.memberRoleSet(identity, role: try Self.role(request.role)))
    }

    /// A root op (the delegable, cleared cascade) on the group's namespace.
    public func deleteGroup(
        _ groupId: String, request: DeleteGroupRequest? = nil
    ) async throws -> DeleteGroupResponseData {
        try requireRelay("deleteGroup")
        try await root(groupId, GovernanceOps.groupDeleted(groupId))
        return DeleteGroupResponseData(isDeleted: true)
    }

    public func reparentGroup(
        _ childGroupId: String, request: ReparentGroupRequest
    ) async throws -> ReparentGroupResponseData {
        try requireRelay("reparentGroup")
        try await root(
            childGroupId, GovernanceOps.groupReparented(childGroupId: childGroupId, newParentId: request.newParentId))
        return ReparentGroupResponseData(reparented: true)
    }

    /// This account's own `MemberLeft` on the group.
    public func leaveGroup(_ groupId: String, request: [String: JSONValue]? = nil) async throws {
        try requireRelay("leaveGroup")
        try await group(groupId, GovernanceOps.memberLeft(session.account))
    }

    public func leaveNamespace(_ namespaceId: String, request: [String: JSONValue]? = nil) async throws {
        try requireRelay("leaveNamespace")
        try await group(namespaceId, GovernanceOps.memberLeft(session.account))
    }

    // MARK: - Joining, creating and inviting

    /// `MemberJoinedOpen` on the context's group, as a node's join sends it.
    public func joinContext(_ contextId: String) async throws -> JoinContextResponseData {
        let groupId = try await contextGroup(contextId)
        _ = try await joinOpen(groupId)
        return JoinContextResponseData(contextId: contextId, memberPublicKey: session.account)
    }

    /// A context through the relay, in the group the request names; the
    /// account is its member key (the relay executes as the account).
    public func createContext(_ request: CreateContextRequest) async throws -> CreateContextResponseData {
        let info = try await forwardedAdmin.getGroupInfo(request.groupId)
        let created = try await deps.createContext(
            session,
            CreateDelegatedContextRequest(
                namespaceId: info.namespaceId ?? request.groupId, groupId: request.groupId,
                applicationId: request.applicationId, serviceName: request.serviceName,
                contextSeed: request.contextSeed, initializationParams: request.initializationParams,
                name: request.name))
        return CreateContextResponseData(
            contextId: created.contextId, memberPublicKey: session.account, groupId: request.groupId)
    }

    /// An invitation signed with the device key, naming the namespace's relays
    /// as admitters (only a relay can admit a joiner with no node), else its
    /// admins. Refused, unsigned, when the cloud's routing says nobody could
    /// claim it. The request's fields are not used: an account signs the
    /// invitation itself, at the longest validity a node allows.
    public func createNamespaceInvitation(
        _ namespaceId: String, request: CreateNamespaceInvitationRequest? = nil
    ) async throws -> CreateNamespaceInvitationResult {
        let invitation = try await Self.mintInvitation(
            namespaceId: namespaceId, session: session, read: try forwardedAdmin, routing: deps.routing,
            sign: deps.signInvitation)
        return .single(CreateNamespaceInvitationResponseData(invitation: invitation))
    }

    /// Redeem an invitation through ``AccountAdminDeps/join``: reachable with
    /// or without a relay, since joining is how an account gets one.
    public func joinNamespace(
        _ namespaceId: String, request: JoinNamespaceRequest
    ) async throws -> JoinNamespaceResponseData {
        guard let join = deps.join else {
            throw AccountError.notForAccount(method: "joinNamespace without a join handler")
        }
        let joined = try await join(namespaceId, request.invitation)
        return JoinNamespaceResponseData(
            namespaceId: joined, memberIdentity: session.account, memberAccount: session.account)
    }

    /// `MemberJoinedOpen` on an open subgroup; a direct member's is a no-op.
    public func joinSubgroupInheritance(_ groupId: String) async throws -> JoinSubgroupInheritanceResponseData {
        try requireRelay("joinSubgroupInheritance")
        let joined = try await joinOpen(groupId)
        return JoinSubgroupInheritanceResponseData(
            groupId: groupId, memberPublicKey: session.account, wasInherited: joined)
    }

    public func detachContextFromGroup(
        _ groupId: String, contextId: String, request: DetachContextFromGroupRequest? = nil
    ) async throws {
        try requireRelay("detachContextFromGroup")
        try await group(groupId, GovernanceOps.contextDetached(contextId))
    }

    /// The relay syncs its own view; an account has nothing to pull. Answers
    /// with the group as the relay sees it.
    public func syncGroup(_ groupId: String, request: SyncGroupRequest? = nil) async throws -> SyncGroupResponseData {
        let info = try await forwardedAdmin.getGroupInfo(groupId)
        return SyncGroupResponseData(
            groupId: groupId, appKey: info.appKey, targetApplicationId: info.targetApplicationId,
            memberCount: info.memberCount, contextCount: info.contextCount)
    }

    /// Nothing for an account to pull: the relay syncs.
    public func syncContext(_ contextId: String? = nil) async throws {
        try requireRelay("syncContext")
    }

    // MARK: - A node's own

    public func upgradeGroup(_ groupId: String, request: UpgradeGroupRequest) async throws -> UpgradeGroupResponseData {
        throw refusal("upgradeGroup")
    }

    public func retryGroupUpgrade(
        _ groupId: String, request: RetryGroupUpgradeRequest? = nil
    ) async throws -> RetryGroupUpgradeResponseData {
        throw refusal("retryGroupUpgrade")
    }

    public func abortMigration(_ namespaceId: String, request: [String: JSONValue]? = nil) async throws -> JSONValue {
        throw refusal("abortMigration")
    }

    public func installApplication(
        _ request: InstallApplicationRequest
    ) async throws -> InstallApplicationResponseData {
        throw refusal("installApplication")
    }

    public func installDevApplication(
        _ request: InstallDevApplicationRequest
    ) async throws -> InstallApplicationResponseData {
        throw refusal("installDevApplication")
    }

    public func uninstallApplication(_ appId: String) async throws -> UninstallApplicationResponseData {
        throw refusal("uninstallApplication")
    }

    public func generateContextIdentity() async throws -> GenerateContextIdentityResponseData {
        throw refusal("generateContextIdentity")
    }

    /// A node drops its own copy; an account's copy is the relay's, shared with
    /// every account it serves. Removing a context for the group is
    /// ``detachContextFromGroup(_:contextId:request:)`` or ``deleteGroup(_:request:)``.
    public func deleteContext(
        _ contextId: String, request: DeleteContextRequest? = nil
    ) async throws -> DeleteContextResponseData {
        throw refusal("deleteContext")
    }

    /// A node's leave is a local opt-out; an account has nothing local. Leaving
    /// the context's group is ``leaveGroup(_:request:)``.
    public func leaveContext(_ contextId: String, request: [String: JSONValue]? = nil) async throws {
        throw refusal("leaveContext")
    }

    public func createContextAlias(_ request: CreateContextAliasRequest) async throws -> CreateAliasResponseData {
        throw refusal("createContextAlias")
    }

    public func createApplicationAlias(
        _ request: CreateApplicationAliasRequest
    ) async throws -> CreateAliasResponseData {
        throw refusal("createApplicationAlias")
    }

    public func createDeviceAlias(_ request: CreateDeviceAliasRequest) async throws -> CreateAliasResponseData {
        throw refusal("createDeviceAlias")
    }

    public func deleteContextAlias(_ name: String) async throws -> DeleteAliasResponseData {
        throw refusal("deleteContextAlias")
    }

    public func deleteApplicationAlias(_ name: String) async throws -> DeleteAliasResponseData {
        throw refusal("deleteApplicationAlias")
    }

    public func deleteDeviceAlias(_ name: String) async throws -> DeleteAliasResponseData {
        throw refusal("deleteDeviceAlias")
    }

    public func lookupContextAlias(_ name: String) async throws -> LookupAliasResponseData {
        throw refusal("lookupContextAlias")
    }

    public func lookupApplicationAlias(_ name: String) async throws -> LookupAliasResponseData {
        throw refusal("lookupApplicationAlias")
    }

    public func lookupDeviceAlias(_ name: String) async throws -> LookupAliasResponseData {
        throw refusal("lookupDeviceAlias")
    }

    public func listContextAliases() async throws -> ListAliasesResponseData {
        throw refusal("listContextAliases")
    }

    public func listApplicationAliases() async throws -> ListAliasesResponseData {
        throw refusal("listApplicationAliases")
    }

    public func listDeviceAliases() async throws -> ListAliasesResponseData {
        throw refusal("listDeviceAliases")
    }

    public func deleteNamespace(
        _ namespaceId: String, request: DeleteNamespaceRequest? = nil
    ) async throws -> DeleteNamespaceResponseData {
        throw refusal("deleteNamespace")
    }

    public func createGroupInvitation(
        _ groupId: String, request: CreateGroupInvitationRequest? = nil
    ) async throws -> CreateGroupInvitationResult {
        throw refusal("createGroupInvitation")
    }

    public func joinGroup(_ request: JoinGroupRequest) async throws -> JoinGroupResponseData {
        throw refusal("joinGroup")
    }

    public func setTeeAdmissionPolicy(_ groupId: String, request: SetTeeAdmissionPolicyRequest) async throws {
        throw refusal("setTeeAdmissionPolicy")
    }

    public func getTeeAdmissionPolicy(_ groupId: String) async throws -> GetTeeAdmissionPolicyResponseData {
        throw refusal("getTeeAdmissionPolicy")
    }

    public func deleteBlob(_ blobId: String) async throws -> DeleteBlobResponseData {
        throw refusal("deleteBlob")
    }

    /// The wallet manages an account's devices, not an app.
    public func listAccountDevices() async throws -> [AccountDeviceEntry] {
        throw refusal("listAccountDevices")
    }

    public func revokeDevice(
        _ namespaceId: String, request: RevokeDeviceRequest
    ) async throws -> RevokeDeviceResponseData {
        throw refusal("revokeDevice")
    }
}

// MARK: - Helpers

extension AccountAdmin {
    /// Refused by name: ``AccountError/noRelay(method:)`` with no relay yet,
    /// else ``AccountError/notForAccount(method:)``.
    func refusal(_ method: String) -> AccountError {
        read == nil ? .noRelay(method: method) : .notForAccount(method: method)
    }

    func requireRelay(_ method: String) throws {
        if read == nil { throw AccountError.noRelay(method: method) }
    }

    /// A group op on `groupId`, once its namespace is known.
    @discardableResult
    func group(_ groupId: String, _ op: Warrants.GovernanceOp) async throws -> String {
        try await knowNamespace(of: groupId)
        return try await deps.governGroup(session, groupId, op)
    }

    /// A root op for `groupId`, posted to its namespace.
    @discardableResult
    func root(_ groupId: String, _ op: Warrants.GovernanceOp) async throws -> String {
        try await knowNamespace(of: groupId)
        return try await deps.governRoot(session, groupId, op)
    }

    /// A subgroup this account neither created nor joined (an open channel
    /// someone else made) is one the relay can name: ask it once, and remember.
    func knowNamespace(of groupId: String) async throws {
        guard DelegatedAccounts.namespaceOfGroup(session, groupId: groupId, store: store) == nil else { return }
        let info = try await forwardedAdmin.getGroupInfo(groupId)
        store.rememberGroupNamespace(
            account: session.account, groupId: groupId, namespaceId: info.namespaceId ?? groupId)
    }

    /// `MemberJoinedOpen` on `groupId`, as a node's join sends it: a member who
    /// only inherits becomes a direct one, and a direct member's join is a
    /// no-op (core refuses it). Returns whether this join made the account a member.
    func joinOpen(_ groupId: String) async throws -> Bool {
        do {
            let op = try GovernanceOps.memberJoinedOpen(
                member: session.account, groupId: groupId, credential: session.credential)
            try await root(groupId, op)
            return true
        } catch let error where Self.isAlreadyDirectMember(error) {
            return false
        }
    }

    func contextGroup(_ contextId: String) async throws -> String {
        guard let groupId = try await forwardedAdmin.getContextGroup(contextId) else {
            throw AccountError.protocolViolation("context \(contextId) belongs to no group the relay knows")
        }
        return groupId
    }

    func isMemberOfContextGroup(_ contextId: String) async throws -> Bool {
        let groupId = try await contextGroup(contextId)
        let members = try await forwardedAdmin.listGroupMembers(groupId).members
        return members.contains { $0.identity.lowercased() == session.account.lowercased() }
    }

    /// Core's refusal of a MemberJoinedOpen from someone already a direct
    /// member (`AlreadyDirectMember`, a `409`): "signer … is a direct member".
    /// Not "is not a direct member", which a leave by an inherited member gets.
    static func isAlreadyDirectMember(_ error: Error) -> Bool {
        let classified = classifyError(error)
        guard classified.status == nil || classified.status == 409 else { return false }
        let text = [classified.message, (error as? LocalizedError)?.errorDescription ?? "", "\(error)"]
            .joined(separator: "\n")
        return text.range(
            of: "signer [0-9a-f]+ is a direct member", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func role(_ name: String) throws -> GovernanceMemberRole {
        guard let role = GovernanceMemberRole(rawValue: name) else {
            throw AccountError.invalidInput("an account can grant Admin, Member or ReadOnly, not \(name)")
        }
        return role
    }

    static func mask(_ value: Int) throws -> UInt32 {
        guard let mask = UInt32(exactly: value) else {
            throw AccountError.invalidInput("capabilities must be a non-negative 32-bit mask, got \(value)")
        }
        return mask
    }

    /// Sign an invitation as the account (``GroupInvitations/sign(groupId:inviterAccount:keys:admitters:members:invitedRole:validForSeconds:now:nonce:applicationId:appKey:admitterAddrs:)``).
    public static func sign(_ input: AccountInvitationInput) throws -> SignedGroupOpenInvitation {
        try GroupInvitations.sign(
            groupId: input.groupId, inviterAccount: input.inviterAccount, keys: input.keys, admitters: input.admitters,
            members: input.members, invitedRole: input.invitedRole, validForSeconds: input.validForSeconds,
            applicationId: input.applicationId, appKey: input.appKey)
    }

    /// Mint an invitation to `namespaceId` as the account: the namespace's
    /// relays as admitters (else its admins), checked against the cloud's
    /// routing first when `routing` is given — the same intersection the
    /// claimant's client makes. A failed routing lookup does not block
    /// minting: the claimant's own lookup will say what is wrong.
    public static func mintInvitation(
        namespaceId: String, session: DelegatedSession, read: any AdminSurface,
        routing: AccountAdminDeps.Routing?,
        invitedRole: GroupInvitations.InvitedRole = .member,
        validForSeconds: Int = GroupInvitations.maxValiditySeconds,
        sign: @Sendable (AccountInvitationInput) throws -> SignedGroupOpenInvitation = { try AccountAdmin.sign($0) }
    ) async throws -> SignedGroupOpenInvitation {
        async let membersCall = read.listGroupMembers(namespaceId)
        async let infoCall = read.getGroupInfo(namespaceId)
        let members = try await membersCall.members
        let info = try await infoCall
        let relays = members.filter { $0.role == "RelayTee" }.map { $0.identity.lowercased() }
        if let routing, let accounts = try? await routing(namespaceId) {
            let named = Set(
                relays.isEmpty
                    ? members.filter { $0.role == "Admin" }.map { $0.identity.lowercased() } : relays)
            guard !accounts.isEmpty else {
                throw AccountError.invitationNotClaimable(
                    namespaceId: namespaceId, reason: InvitationNotClaimableReason.notHosted.rawValue)
            }
            guard accounts.contains(where: { $0.map { named.contains($0.lowercased()) } == true }) else {
                throw AccountError.invitationNotClaimable(
                    namespaceId: namespaceId, reason: InvitationNotClaimableReason.noNamedNode.rawValue)
            }
        }
        return try sign(
            AccountInvitationInput(
                groupId: namespaceId, inviterAccount: session.account, keys: session.keys, admitters: relays,
                members: members, applicationId: Hex.is32(info.targetApplicationId) ? info.targetApplicationId : nil,
                appKey: Hex.is32(info.appKey) ? info.appKey : nil, invitedRole: invitedRole,
                validForSeconds: validForSeconds))
    }
}

/// A node's admin as an app writes against it: ``AdminApi`` with
/// `createNamespace` made whole. On a node a namespace can only be created for
/// an application the node already holds, so this installs the app's package
/// from the registry first when it is missing — the step an account never
/// sees, because founding through a relay names the package. Same call, same
/// result, on both. (== mero-js `createNodeAdmin`.)
public struct NodeAdmin: AdminApiForwarding {
    public let admin: AdminApi
    public let app: AdminAppConfig
    private let latestVersion: @Sendable (String, String) async throws -> String

    /// - Parameter latestVersion: `(registryURL, package) → version`; the
    ///   registry's newest non-yanked version by default.
    public init(
        admin: AdminApi, app: AdminAppConfig = AdminAppConfig(),
        latestVersion: (@Sendable (String, String) async throws -> String)? = nil
    ) {
        self.admin = admin
        self.app = app
        if let latestVersion {
            self.latestVersion = latestVersion
        } else {
            self.latestVersion = { registry, package in
                try await DelegatedAccounts.latestPublishedVersion(registryURL: registry, package: package)
            }
        }
    }

    public var forwardedAdmin: AdminApi { admin }

    /// Install the app first when the node lacks it, then create.
    public func createNamespace(_ request: CreateNamespaceRequest) async throws -> CreateNamespaceResponseData {
        try await ensureInstalled(request.applicationId)
        return try await admin.createNamespace(request)
    }

    private func ensureInstalled(_ applicationId: String) async throws {
        let apps = try await admin.listApplications().apps
        if apps.contains(where: { $0.id == applicationId }) { return }
        guard let package = app.packageName else {
            throw AccountError.invalidInput(
                "application \(applicationId) is not installed on this node, and no packageName is set to install it")
        }
        let version: String
        if let pinned = app.packageVersion {
            version = pinned
        } else {
            version = try await latestVersion(app.registry, package)
        }
        let installed = try await admin.installApplication(
            InstallApplicationRequest(package: package, version: version))
        // A registry bundle signed by a different key is a different
        // application: creating against it would found a namespace for another app.
        guard installed.applicationId == applicationId else {
            throw AccountError.protocolViolation(
                "installed \(package)@\(version) as \(installed.applicationId), not \(applicationId)")
        }
    }
}

extension DelegatedAccounts {
    /// An account's admin over `read` (the delegated client's
    /// ``MeroTransportClient/admin``, or `nil` with no relay yet).
    /// (== mero-js `createAccountAdmin`.)
    public static func createAccountAdmin(
        session: DelegatedSession, read: AdminApi?, app: AdminAppConfig = AdminAppConfig(),
        env: DelegatedEnvironment = DelegatedEnvironment(), deps: AccountAdminDeps? = nil
    ) -> AccountAdmin {
        AccountAdmin(session: session, read: read, app: app, env: env, deps: deps)
    }

    /// A node's admin that installs `app` before founding on it. (== mero-js `createNodeAdmin`.)
    public static func createNodeAdmin(admin: AdminApi, app: AdminAppConfig = AdminAppConfig()) -> NodeAdmin {
        NodeAdmin(admin: admin, app: app)
    }
}
