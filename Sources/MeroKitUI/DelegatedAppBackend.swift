import Foundation
import MeroKit

/// ``MeroAppBackend`` for a Calimero Cloud account, delegated end to end: a
/// snapshot of one connection, which ``MeroAppSession`` rebuilds when the
/// session changes. (== Kotlin `com.calimero.mero.compose.DelegatedAppBackend`.)
///
/// - Contract calls: ``RelayContextContract`` over the connection's
///   ``RelayClient`` (relay query / warrant intents); ``NoRelayContextContract``
///   while no relay serves the account.
/// - Listings: the account's admin (``AccountAdmin``), whose reads are the
///   relay's caller-scoped admin API.
/// - Subgroups and contexts: ``AccountAdmin`` turns `createGroupInNamespace`,
///   `setSubgroupVisibility`, `createContext` and `joinContext` into governance
///   and context intents posted to the namespace's relay.
/// - Namespaces: ``CloudSignIn/foundNamespace(_:name:package:application:defaultCapabilities:registryURL:)``
///   founds through the relay; ``CloudSignIn/createNamespaceInvitation(_:namespaceId:invitedRole:validForSeconds:)``
///   signs invitations with the device key; ``CloudSignIn/join(namespaceId:invitation:nodeURL:)``
///   is direct admission (`POST …/namespaces/{id}/admit`) through the relay the cloud routes to.
/// - Names, members, leaving and deleting: ``AccountAdmin`` reads them from the
///   relay's caller-scoped admin (`/groups/{id}/contexts`, `/members`,
///   `/metadata`) and turns each write into its governance op
///   (`GroupMetadataSet`, `ContextMetadataSet`, `MemberMetadataSet`,
///   `MemberRoleSet`, `MemberRemoved`, `MemberLeft`, `GroupDeleted`,
///   `ContextDetached`) on the namespace's relay.
/// - Blobs: the relay's blob routes, through a context the account is a member of.
/// - Live updates: SSE on the relay through the connection's Bearer ``Mero``.
public struct DelegatedAppBackend: MeroAppBackend {
    public let account: String
    public let contract: any ContextContract
    public let connection: CloudConnection
    public let admin: any AdminSurface
    public let signIn: CloudSignIn
    /// The app's registry package: what a namespace is founded with.
    public let packageName: String
    /// The registry ``packageName`` is resolved in.
    public let registryURL: String
    /// The app's application id, when known: ``listNamespaces()`` keeps only
    /// the namespaces running it. `nil` lists every namespace.
    public let applicationId: String?
    /// What a new namespace is founded with. `nil` resolves ``packageName``
    /// from the registry; a test names the bundle installed on its relay,
    /// which the registry does not list.
    public let foundingApplication: FoundingApplication?
    /// Where to send a join. `nil` asks the Cloud manager for the admitting
    /// relay; a test with no cloud names its relay.
    public let joinNodeURL: String?

    public init(
        connection: CloudConnection, admin: any AdminSurface, signIn: CloudSignIn, packageName: String,
        registryURL: String = ApplicationRegistry.defaultURL, applicationId: String? = nil,
        foundingApplication: FoundingApplication? = nil, joinNodeURL: String? = nil
    ) {
        self.account = connection.session.account
        self.connection = connection
        self.admin = admin
        self.signIn = signIn
        self.packageName = packageName
        self.registryURL = registryURL
        self.applicationId = applicationId
        self.foundingApplication = foundingApplication
        self.joinNodeURL = joinNodeURL
        if let relay = connection.relay {
            contract = RelayContextContract(relay: relay)
        } else {
            contract = NoRelayContextContract()
        }
    }

    public var hasRelay: Bool { connection.relay != nil }
    public var canSubscribe: Bool { connection.mero != nil }

    public func listNamespaces() async throws -> [AppNamespace] {
        let all = try await admin.listNamespaces()
        let mine = applicationId.map { app in all.filter { $0.targetApplicationId.lowercased() == app.lowercased() } }
        return (mine ?? all).map {
            AppNamespace(
                id: $0.namespaceId, name: $0.name, applicationId: $0.targetApplicationId, memberCount: $0.memberCount)
        }
    }

    public func listSubgroups(namespaceId: String) async throws -> [AppSubgroup] {
        let subgroups = try await admin.listSubgroups(namespaceId)
        let admin = self.admin
        return await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, subgroup) in subgroups.enumerated() {
                group.addTask {
                    // A subgroup whose contexts cannot be read still lists, empty.
                    (index, (try? await admin.listGroupContexts(subgroup.groupId))?.map(\.contextId) ?? [])
                }
            }
            var contexts = [[String]](repeating: [], count: subgroups.count)
            for await (index, ids) in group { contexts[index] = ids }
            return subgroups.enumerated().map {
                AppSubgroup(groupId: $0.element.groupId, name: $0.element.name, contextIds: contexts[$0.offset])
            }
        }
    }

    public func listContexts(groupId: String) async throws -> [String] {
        try await admin.listGroupContexts(groupId).map(\.contextId)
    }

    public func isMember(contextId: String) async throws -> Bool {
        !(try await admin.getContextIdentitiesOwned(contextId).identities.isEmpty)
    }

    public func joinContext(contextId: String) async throws {
        _ = try await admin.joinContext(contextId)
    }

    public func foundNamespace(name: String) async throws -> AppFoundedNamespace {
        let founded = try await signIn.foundNamespace(
            connection, name: name, package: packageName, application: foundingApplication, registryURL: registryURL)
        return AppFoundedNamespace(namespaceId: founded.namespaceId, haEnabled: founded.haEnabled, haError: founded.haError)
    }

    public func createSubgroup(namespaceId: String, name: String, isPublic: Bool) async throws -> String {
        let visibility = isPublic ? "open" : "restricted"
        // Born with its visibility (a subgroup created restricted and flipped
        // open strands every member outside it), then set explicitly as well,
        // as the web apps do. A failure of the second is not fatal.
        let created = try await admin.createGroupInNamespace(
            namespaceId, request: CreateGroupInNamespaceRequest(groupName: name, visibility: visibility))
        try? await admin.setSubgroupVisibility(
            created.groupId, request: SetSubgroupVisibilityRequest(subgroupVisibility: visibility))
        return created.groupId
    }

    public func createContext(
        groupId: String, applicationId: String, name: String, initArgs: JSONValue
    ) async throws -> String {
        let created = try await admin.createContext(
            CreateContextRequest(
                applicationId: applicationId, groupId: groupId,
                initializationParams: CanonicalJSON.data(initArgs).map { Int($0) }, name: name))
        return created.contextId
    }

    public func createInvitation(namespaceId: String) async throws -> SignedGroupOpenInvitation {
        try await signIn.createNamespaceInvitation(connection, namespaceId: namespaceId)
    }

    public func joinNamespace(
        namespaceId: String, invitation: SignedGroupOpenInvitation
    ) async throws -> AppJoinedNamespace {
        let (_, outcome) = try await signIn.join(namespaceId: namespaceId, invitation: invitation, nodeURL: joinNodeURL)
        return AppJoinedNamespace(namespaceId: namespaceId, published: outcome.published, relayURL: outcome.relayUrl)
    }

    // MARK: Names

    public func listContextEntries(groupId: String) async throws -> [AppContextEntry] {
        try await admin.listGroupContexts(groupId).map { AppContextEntry(id: $0.contextId, name: $0.name) }
    }

    public func groupMetadata(groupId: String) async throws -> AppMetadata? {
        try await admin.getGroupMetadata(groupId).map(Self.metadata)
    }

    public func contextMetadata(groupId: String, contextId: String) async throws -> AppMetadata? {
        try await admin.getContextMetadata(groupId, contextId: contextId).map(Self.metadata)
    }

    /// Setting metadata replaces the whole record, so the current `data` is
    /// read first and sent back with the new name.
    public func setGroupName(groupId: String, name: String) async throws {
        let data = try await admin.getGroupMetadata(groupId)?.data
        try await admin.setGroupMetadata(groupId, request: SetGroupMetadataRequest(name: name, data: data))
    }

    public func setContextName(groupId: String, contextId: String, name: String) async throws {
        let data = try await admin.getContextMetadata(groupId, contextId: contextId)?.data
        try await admin.setContextMetadata(
            groupId, contextId: contextId, request: SetContextMetadataRequest(name: name, data: data))
    }

    // MARK: Blobs

    public func uploadBlob(contextId: String, data: Data) async throws -> AppBlob {
        let stored = try await admin.uploadBlob(UploadBlobRequest(data: data, contextId: contextId))
        return AppBlob(blobId: stored.blobId, size: stored.size)
    }

    public func getBlob(blobId: String, contextId: String) async throws -> Data {
        try await admin.getBlob(blobId, contextId: contextId)
    }

    // MARK: Leaving and deleting

    public func leaveNamespace(namespaceId: String) async throws {
        try await admin.leaveNamespace(namespaceId, request: nil)
    }

    public func leaveSubgroup(groupId: String) async throws {
        try await admin.leaveGroup(groupId, request: nil)
    }

    public func deleteSubgroup(groupId: String) async throws {
        _ = try await admin.deleteGroup(groupId, request: nil)
    }

    public func removeContext(groupId: String, contextId: String) async throws {
        try await admin.detachContextFromGroup(groupId, contextId: contextId, request: nil)
    }

    // MARK: Members

    public func listMembers(groupId: String) async throws -> [AppMember] {
        try await admin.listGroupMembers(groupId).members.map {
            AppMember(identity: $0.identity, role: $0.role, name: $0.name)
        }
    }

    public func setMemberRole(groupId: String, identity: String, role: GovernanceMemberRole) async throws {
        try await admin.updateMemberRole(
            groupId, identity: identity, request: UpdateMemberRoleRequest(role: role.rawValue))
    }

    public func removeMember(groupId: String, identity: String) async throws {
        try await admin.removeGroupMembers(groupId, request: RemoveGroupMembersRequest(members: [identity]))
    }

    public func setMemberName(groupId: String, name: String) async throws {
        let data = try await admin.getMemberMetadata(groupId, identity: account)?.data
        try await admin.setMemberMetadata(
            groupId, identity: account, request: SetMemberMetadataRequest(name: name, data: data))
    }

    private static func metadata(_ record: MetadataRecord) -> AppMetadata {
        AppMetadata(name: record.name, data: record.data)
    }

    // MARK: Events

    public func events(contextId: String) -> AsyncThrowingStream<AppContextEvent, Error> {
        guard let mero = connection.mero else {
            return AsyncThrowingStream { $0.finish() }
        }
        let upstream = mero.events(contextIds: [contextId])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream where event.contextId == contextId {
                        continuation.yield(AppContextEvent(contextId: event.contextId, kind: event.kind))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
