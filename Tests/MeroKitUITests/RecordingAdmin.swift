import Foundation
import MeroKit

/// An ``AdminSurface`` that answers the calls ``DelegatedAppBackend``'s
/// names, blobs, leaving and members make, and records them. Anything else
/// throws (`forwardedAdmin` has nowhere to send it).
final class RecordingAdmin: AdminApiForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var metadata: [String: MetadataRecord] = [:]
    var members: [GroupMember] = []
    var contexts: [GroupContextEntry] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var forwardedAdmin: AdminApi {
        get throws { throw AccountError.notForAccount(method: "unscripted") }
    }

    private func record(_ entry: String) {
        lock.lock()
        recorded.append(entry)
        lock.unlock()
    }

    private static func describe(_ request: SetMetadataRequest) -> String {
        "\(request.name ?? "-") \((request.data ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })"
    }

    func listGroupContexts(_ groupId: String) async throws -> ListGroupContextsResponseData {
        record("listGroupContexts \(groupId)")
        return contexts
    }

    func getGroupMetadata(_ groupId: String) async throws -> MetadataRecord? {
        record("getGroupMetadata \(groupId)")
        return metadata[groupId]
    }

    func getContextMetadata(_ groupId: String, contextId: String) async throws -> MetadataRecord? {
        record("getContextMetadata \(groupId) \(contextId)")
        return metadata[contextId]
    }

    func getMemberMetadata(_ groupId: String, identity: String) async throws -> MetadataRecord? {
        record("getMemberMetadata \(groupId) \(identity)")
        return metadata[identity]
    }

    func setGroupMetadata(_ groupId: String, request: SetGroupMetadataRequest) async throws {
        record("setGroupMetadata \(groupId) \(Self.describe(request))")
    }

    func setContextMetadata(_ groupId: String, contextId: String, request: SetContextMetadataRequest) async throws {
        record("setContextMetadata \(groupId) \(contextId) \(Self.describe(request))")
    }

    func setMemberMetadata(_ groupId: String, identity: String, request: SetMemberMetadataRequest) async throws {
        record("setMemberMetadata \(groupId) \(identity) \(Self.describe(request))")
    }

    func uploadBlob(_ request: UploadBlobRequest) async throws -> UploadBlobResponseData {
        record("uploadBlob \(request.contextId ?? "-") \(request.data.count)")
        return BlobInfo(blobId: "blob1", size: request.data.count)
    }

    func getBlob(_ blobId: String, contextId: String?) async throws -> Data {
        record("getBlob \(blobId) \(contextId ?? "-")")
        return Data("bytes".utf8)
    }

    func leaveNamespace(_ namespaceId: String, request: [String: JSONValue]?) async throws {
        record("leaveNamespace \(namespaceId)")
    }

    func leaveGroup(_ groupId: String, request: [String: JSONValue]?) async throws {
        record("leaveGroup \(groupId)")
    }

    func deleteGroup(_ groupId: String, request: DeleteGroupRequest?) async throws -> DeleteGroupResponseData {
        record("deleteGroup \(groupId)")
        return DeleteGroupResponseData(isDeleted: true)
    }

    func detachContextFromGroup(
        _ groupId: String, contextId: String, request: DetachContextFromGroupRequest?
    ) async throws {
        record("detachContextFromGroup \(groupId) \(contextId)")
    }

    func listGroupMembers(_ groupId: String) async throws -> ListGroupMembersResponseData {
        record("listGroupMembers \(groupId)")
        return ListGroupMembersResponseData(members: members)
    }

    func updateMemberRole(_ groupId: String, identity: String, request: UpdateMemberRoleRequest) async throws {
        record("updateMemberRole \(groupId) \(identity) \(request.role)")
    }

    func removeGroupMembers(_ groupId: String, request: RemoveGroupMembersRequest) async throws {
        record("removeGroupMembers \(groupId) \(request.members)")
    }
}
