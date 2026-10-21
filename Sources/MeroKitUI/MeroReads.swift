import Foundation
import MeroKit

// The read hooks of mero-react (`src/hooks/index.ts`) as factories on
// ``MeroClient``: each returns an ``AsyncResource`` bound to the client, so it
// re-reads when the session changes and resets when its input does. Keep the
// resource in a `@StateObject` (or a view model) for as long as the view
// shows it; make a new one for a new input.
//
// Every read is disabled (`data` stays at its initial value, nothing is sent)
// while the client has no ``MeroClient/admin`` or an input is `nil`.

/// A context and the application it runs. (== mero-react `ApplicationContextRecord`.)
public struct ApplicationContextRecord: Sendable, Equatable, Hashable {
    public let contextId: String
    public let applicationId: String

    public init(contextId: String, applicationId: String) {
        self.contextId = contextId
        self.applicationId = applicationId
    }
}

extension MeroClient {
    /// A resource whose fetcher `make` derives from this client, now and after
    /// every session change.
    public func resource<Value: Sendable>(
        initial: Value, _ make: @escaping @MainActor @Sendable (MeroClient) -> AsyncResource<Value>.Fetcher?
    ) -> AsyncResource<Value> {
        AsyncResource(initial: initial, autoload: false).bind(to: self, make)
    }

    /// A resource over ``admin``, enabled when there is one.
    func adminResource<Value: Sendable>(
        initial: Value, _ read: @escaping @Sendable (any AdminSurface) async throws -> Value
    ) -> AsyncResource<Value> {
        resource(initial: initial) { client in
            guard let admin = client.admin else { return nil }
            return { try await read(admin) }
        }
    }

    // MARK: - Contexts

    /// This session's contexts, optionally only `applicationId`'s.
    /// (== mero-react `useContexts` / `useApplicationContexts`.)
    ///
    /// An account lists its own contexts on every relay it uses and filters
    /// here: the per-application listing is node-wide, so a relay refuses it.
    public func contexts(applicationId: String? = nil) -> AsyncResource<[ApplicationContextRecord]> {
        resource(initial: []) { client in
            guard client.admin != nil else { return nil }
            if let session = client.delegatedSession {
                let env = client.delegatedEnvironment
                return {
                    try await DelegatedAccounts.listDelegatedContexts(session, env: env)
                        .filter { applicationId == nil || $0.item.applicationId == applicationId }
                        .map { ApplicationContextRecord(contextId: $0.item.id, applicationId: $0.item.applicationId) }
                }
            }
            guard let read = client.readAdmin else { return nil }
            return {
                let listed: GetContextsResponseData
                if let applicationId {
                    listed = try await read.getContextsForApplication(applicationId)
                } else {
                    listed = try await read.getContexts()
                }
                return listed.contexts.map {
                    ApplicationContextRecord(contextId: $0.id, applicationId: $0.applicationId)
                }
            }
        }
    }

    /// ``contexts(applicationId:)``. (== mero-react `useApplicationContexts`.)
    public func applicationContexts(_ applicationId: String?) -> AsyncResource<[ApplicationContextRecord]> {
        contexts(applicationId: applicationId)
    }

    /// The group a context belongs to. (== mero-react `useContextGroup`.)
    public func contextGroup(_ contextId: String?) -> AsyncResource<String?> {
        guard let contextId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getContextGroup(contextId) }
    }

    // MARK: - Groups

    /// (== mero-react `useGroupInfo`.)
    public func groupInfo(_ groupId: String?) -> AsyncResource<GroupInfo?> {
        guard let groupId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getGroupInfo(groupId) }
    }

    /// A group's members, keyed by ACCOUNT (not signing key).
    /// (== mero-react `useGroupMembers`.)
    public func groupMembers(_ groupId: String?) -> AsyncResource<[GroupMember]> {
        guard let groupId else { return AsyncResource(initial: []) }
        return adminResource(initial: []) { try await $0.listGroupMembers(groupId).members }
    }

    /// (== mero-react `useGroupContexts`.)
    public func groupContexts(_ groupId: String?) -> AsyncResource<[GroupContextEntry]> {
        guard let groupId else { return AsyncResource(initial: []) }
        return adminResource(initial: []) { try await $0.listGroupContexts(groupId) }
    }

    /// (== mero-react `useSubgroups`.)
    public func subgroups(_ groupId: String?) -> AsyncResource<[SubgroupEntry]> {
        guard let groupId else { return AsyncResource(initial: []) }
        return adminResource(initial: []) { try await $0.listSubgroups(groupId) }
    }

    /// (== mero-react `useDefaultCapabilities`.)
    public func defaultCapabilities(_ groupId: String?) -> AsyncResource<Int?> {
        guard let groupId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getDefaultCapabilities(groupId) }
    }

    /// (== mero-react `useSubgroupVisibility`.) How the group takes members, not
    /// whether it is private: draw a lock from `groupInfo(_:)`'s
    /// `effectiveVisibility`.
    public func subgroupVisibility(_ groupId: String?) -> AsyncResource<String?> {
        guard let groupId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getSubgroupVisibility(groupId) }
    }

    /// A group's TEE admission policy.
    public func teeAdmissionPolicy(_ groupId: String?) -> AsyncResource<GetTeeAdmissionPolicyResponseData?> {
        guard let groupId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getTeeAdmissionPolicy(groupId) }
    }

    /// (== mero-react `useGroupUpgradeStatus`.)
    public func groupUpgradeStatus(_ groupId: String?) -> AsyncResource<GroupUpgradeStatus?> {
        guard let groupId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getGroupUpgradeStatus(groupId) }
    }

    // MARK: - Metadata

    /// (== mero-react `useGroupMetadata`.)
    public func groupMetadata(_ groupId: String?) -> AsyncResource<MetadataRecord?> {
        guard let groupId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getGroupMetadata(groupId) }
    }

    /// A member's metadata; `identity` is the member's ACCOUNT.
    /// (== mero-react `useMemberMetadata`.)
    public func memberMetadata(_ groupId: String?, identity: String?) -> AsyncResource<MetadataRecord?> {
        guard let groupId, let identity else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getMemberMetadata(groupId, identity: identity) }
    }

    /// A context's metadata within its group.
    public func contextMetadata(_ groupId: String?, contextId: String?) -> AsyncResource<MetadataRecord?> {
        guard let groupId, let contextId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getContextMetadata(groupId, contextId: contextId) }
    }

    // MARK: - Namespaces

    /// (== mero-react `useNamespaces`.)
    public func namespaces() -> AsyncResource<[Namespace]> {
        adminResource(initial: []) { try await $0.listNamespaces() }
    }

    /// (== mero-react `useNamespace`.)
    public func namespace(_ namespaceId: String?) -> AsyncResource<Namespace?> {
        guard let namespaceId else { return AsyncResource(initial: nil) }
        return adminResource(initial: nil) { try await $0.getNamespace(namespaceId) }
    }

    /// Who this node (or account) is: `accountId` is what member calls take.
    /// (== mero-react `useNodeIdentity`.)
    public func nodeIdentity() -> AsyncResource<NodeIdentity?> {
        adminResource(initial: nil) { try await $0.getNodeIdentity() }
    }

    /// The namespaces running `applicationId`. An account lists its own on
    /// every relay and filters. (== mero-react `useNamespacesForApplication`.)
    public func namespacesForApplication(_ applicationId: String?) -> AsyncResource<[Namespace]> {
        guard let applicationId else { return AsyncResource(initial: []) }
        return resource(initial: []) { client in
            guard let admin = client.admin else { return nil }
            if let session = client.delegatedSession {
                let env = client.delegatedEnvironment
                return {
                    try await DelegatedAccounts.listDelegatedNamespaces(session, env: env).map(\.item)
                        .filter { $0.targetApplicationId == applicationId }
                }
            }
            return { try await admin.listNamespacesForApplication(applicationId) }
        }
    }

    /// (== mero-react `useNamespaceGroups`.)
    public func namespaceGroups(_ namespaceId: String?) -> AsyncResource<[SubgroupEntry]> {
        guard let namespaceId else { return AsyncResource(initial: []) }
        return adminResource(initial: []) { try await $0.listNamespaceGroups(namespaceId) }
    }

    // MARK: - Blobs

    /// A blob's presence and size, without downloading it. With `contextId`
    /// the node probes that context's peers (up to core's ~30 s deadline).
    /// (== mero-react `useBlobInfo`; read ``isBlobNotFound(_:)`` off `error`.)
    public func blobInfo(_ blobId: String?, contextId: String? = nil) -> AsyncResource<GetBlobInfoResponseData?> {
        guard let blobId else { return AsyncResource(initial: nil) }
        return resource(initial: nil) { client in
            guard client.admin != nil, let read = client.readAdmin else { return nil }
            return { try await read.getBlobInfo(blobId, contextId: contextId) }
        }
    }
}

/// Whether `error` is the node saying nobody holds the blob (HTTP 404),
/// rather than a transport or auth failure. (== mero-react `notFound`.)
public func isBlobNotFound(_ error: Error?) -> Bool {
    guard let error else { return false }
    return classifyError(error).status == 404
}
