// Admin API Types — aligned with core server routes.
//
// Ported 1:1 from mero-js `src/admin-api/admin-types.ts`.
//
// IMPORTANT wire-format note: the core admin API serializes these DTOs with
// `#[serde(rename_all = "camelCase")]`, so the JSON on the wire is camelCase
// for essentially every type here — NOT snake_case. The Swift property names
// therefore map 1:1 to the wire without any `CodingKeys` remapping, and the
// default `JSONEncoder`/`JSONDecoder` (no key strategy) round-trips them
// correctly.
//
// The genuine snake_case quirks are documented and handled explicitly:
//   * `Application.signerId`  <-  wire `signer_id`  (see CodingKeys below)
//   * blob DTOs use `blob_id` on the wire — decoded via internal wire structs
//     in AdminApi and surfaced here as clean camelCase (`blobId`), see the
//     blob section and `DeleteBlobResponseData`.
//   * the blob upload/announce query params `hash` / `context_id` (snake) are
//     built in AdminApi.

import Foundation

// MARK: - Health and Status

public struct HealthStatus: Codable, Sendable {
    public let status: String
    public init(status: String) { self.status = status }
}

/// NOTE: unlike most reads this is NOT unwrapped — `isAuthed` returns the whole
/// envelope, which core shapes as `{ data: { status } }`.
public struct AdminAuthStatus: Codable, Sendable {
    public struct StatusInner: Codable, Sendable {
        public let status: String
        public init(status: String) { self.status = status }
    }
    public let data: StatusInner
    public init(data: StatusInner) { self.data = data }
}

// MARK: - Applications

public struct InstallApplicationRequest: Codable, Sendable {
    public var url: String
    public var hash: String?
    public var metadata: [Int]
    public var package: String?
    public var version: String?
    public init(url: String, hash: String? = nil, metadata: [Int], package: String? = nil, version: String? = nil) {
        self.url = url; self.hash = hash; self.metadata = metadata; self.package = package; self.version = version
    }
}

public struct InstallDevApplicationRequest: Codable, Sendable {
    public var path: String
    public var metadata: [Int]
    public var package: String?
    public var version: String?
    public init(path: String, metadata: [Int], package: String? = nil, version: String? = nil) {
        self.path = path; self.metadata = metadata; self.package = package; self.version = version
    }
}

public struct InstallApplicationResponseData: Codable, Sendable {
    public let applicationId: String
    public init(applicationId: String) { self.applicationId = applicationId }
}

public struct UninstallApplicationResponseData: Codable, Sendable {
    public let applicationId: String
    public init(applicationId: String) { self.applicationId = applicationId }
}

public struct ApplicationBlob: Codable, Sendable {
    public let bytecode: String
    public let compiled: String
    public init(bytecode: String, compiled: String) { self.bytecode = bytecode; self.compiled = compiled }
}

public struct Application: Codable, Sendable {
    public let id: String
    public let blob: ApplicationBlob
    public let size: Int
    public let source: String
    public let metadata: [Int]
    /// QUIRK: this lone field is `signer_id` (snake_case) on the wire, inside an
    /// otherwise camelCase DTO — mapped explicitly below.
    public let signerId: String
    public let package: String
    public let version: String

    public init(
        id: String, blob: ApplicationBlob, size: Int, source: String, metadata: [Int], signerId: String,
        package: String, version: String
    ) {
        self.id = id; self.blob = blob; self.size = size; self.source = source
        self.metadata = metadata; self.signerId = signerId; self.package = package; self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case id, blob, size, source, metadata
        case signerId = "signer_id"
        case package, version
    }
}

public struct ListApplicationsResponseData: Codable, Sendable {
    public let apps: [Application]
    public init(apps: [Application]) { self.apps = apps }
}

public struct GetApplicationResponseData: Codable, Sendable {
    public let application: Application?
    public init(application: Application?) { self.application = application }
}

/// One installed blob for an application (distinct from the package registry).
public struct ApplicationVersionEntry: Codable, Sendable {
    public let version: String
    public let blobId: String
    public let size: Int
    public let package: String
    public init(version: String, blobId: String, size: Int, package: String) {
        self.version = version; self.blobId = blobId; self.size = size; self.package = package
    }
}

public struct ListApplicationVersionsResponseData: Codable, Sendable {
    public let data: [ApplicationVersionEntry]
    public init(data: [ApplicationVersionEntry]) { self.data = data }
}

// MARK: - Packages

public struct GetLatestVersionResponseData: Codable, Sendable {
    public let applicationId: String?
    public let version: String?
    public init(applicationId: String?, version: String?) { self.applicationId = applicationId; self.version = version }
}

public struct ListPackagesResponseData: Codable, Sendable {
    public let packages: [String]
    public init(packages: [String]) { self.packages = packages }
}

public struct ListVersionsResponseData: Codable, Sendable {
    public let versions: [String]
    public init(versions: [String]) { self.versions = versions }
}

// MARK: - Bundle migration metadata

/// Per-service migration descriptor carried in a multi-service bundle manifest,
/// emitted from the app's `#[app::migrate]` declaration. `toSchemaVersion` is the
/// CRDT schema version the migrate targets (the engine's gate); `toVersion` is
/// the user-facing bundle semver an admin matches on; `method` is the migrate
/// entrypoint.
public struct BundleMigration: Codable, Sendable {
    public let method: String
    public let toSchemaVersion: Int
    public let toVersion: String?
    public init(method: String, toSchemaVersion: Int, toVersion: String? = nil) {
        self.method = method; self.toSchemaVersion = toSchemaVersion; self.toVersion = toVersion
    }
}

/// The subset of a registry bundle manifest that `installFromRegistry` consumes
/// to resolve an artifact URL. The registry serves it at
/// `GET {registry}/api/v2/bundles/{package}/{version}`.
public struct RegistryBundleManifest: Codable, Sendable {
    public let package: String
    public let appVersion: String
    /// Present when this bundle's app declares a migration.
    public let migration: BundleMigration?
    public init(package: String, appVersion: String, migration: BundleMigration? = nil) {
        self.package = package; self.appVersion = appVersion; self.migration = migration
    }
}

// MARK: - Contexts

public struct CreateContextRequest: Codable, Sendable {
    public var applicationId: String
    public var groupId: String
    public var serviceName: String?
    public var contextSeed: String?
    public var initializationParams: [Int]?
    public var identitySecret: String?
    /// Optional human-readable label for the context.
    public var name: String?
    public init(
        applicationId: String, groupId: String, serviceName: String? = nil, contextSeed: String? = nil,
        initializationParams: [Int]? = nil, identitySecret: String? = nil, name: String? = nil
    ) {
        self.applicationId = applicationId; self.groupId = groupId; self.serviceName = serviceName
        self.contextSeed = contextSeed; self.initializationParams = initializationParams
        self.identitySecret = identitySecret; self.name = name
    }
}

public struct CreateContextResponseData: Codable, Sendable {
    public let contextId: String
    public let memberPublicKey: String
    public let groupId: String?
    public let groupCreated: Bool?
    public init(contextId: String, memberPublicKey: String, groupId: String? = nil, groupCreated: Bool? = nil) {
        self.contextId = contextId; self.memberPublicKey = memberPublicKey; self.groupId = groupId
        self.groupCreated = groupCreated
    }
}

public struct DeleteContextRequest: Codable, Sendable {
    public var requester: String?
    public init(requester: String? = nil) { self.requester = requester }
}

public struct DeleteContextResponseData: Codable, Sendable {
    public let isDeleted: Bool
    public init(isDeleted: Bool) { self.isDeleted = isDeleted }
}

public struct Context: Codable, Sendable {
    public let id: String
    public let applicationId: String
    public let serviceName: String?
    /// Context state/root hash. Core's wire key is `contextStateHash` (part of the
    /// cross-DAG auth three-level naming: contextStateHash / groupStateHash /
    /// namespaceStateHash). Renamed from `rootHash`, which never populated.
    public let contextStateHash: String
    public let dagHeads: [[Int]]
    /// Bundle semver of the installed application (skew #2). Absent on older nodes.
    public let applicationVersion: String?
    public init(
        id: String, applicationId: String, serviceName: String? = nil, contextStateHash: String,
        dagHeads: [[Int]], applicationVersion: String? = nil
    ) {
        self.id = id; self.applicationId = applicationId; self.serviceName = serviceName
        self.contextStateHash = contextStateHash; self.dagHeads = dagHeads; self.applicationVersion = applicationVersion
    }
}

/// `ContextWithGroup` — Swift has no struct inheritance, so this repeats
/// `Context`'s fields and adds the optional `groupId`.
public struct ContextWithGroup: Codable, Sendable {
    public let id: String
    public let applicationId: String
    public let serviceName: String?
    public let contextStateHash: String
    public let dagHeads: [[Int]]
    public let applicationVersion: String?
    public let groupId: String?
    public init(
        id: String, applicationId: String, serviceName: String? = nil, contextStateHash: String,
        dagHeads: [[Int]], applicationVersion: String? = nil, groupId: String? = nil
    ) {
        self.id = id; self.applicationId = applicationId; self.serviceName = serviceName
        self.contextStateHash = contextStateHash; self.dagHeads = dagHeads
        self.applicationVersion = applicationVersion; self.groupId = groupId
    }
}

public struct GetContextsResponseData: Codable, Sendable {
    public let contexts: [ContextWithGroup]
    public init(contexts: [ContextWithGroup]) { self.contexts = contexts }
}

// MARK: - Context Identity

public struct GenerateContextIdentityResponseData: Codable, Sendable {
    public let publicKey: String
    public init(publicKey: String) { self.publicKey = publicKey }
}

public struct GetContextIdentitiesResponseData: Codable, Sendable {
    public let identities: [String]
    public init(identities: [String]) { self.identities = identities }
}

// MARK: - Context join (group membership; POST /contexts/:id/join)

public struct JoinContextResponseData: Codable, Sendable {
    public let contextId: String
    public let memberPublicKey: String
    public init(contextId: String, memberPublicKey: String) {
        self.contextId = contextId; self.memberPublicKey = memberPublicKey
    }
}

// MARK: - Open subgroup join via inheritance (POST /groups/:group_id/join-via-inheritance)

public struct JoinSubgroupInheritanceResponseData: Codable, Sendable {
    public let groupId: String
    public let memberPublicKey: String
    /// `true` if the call had to publish a `MemberJoinedOpen` op to materialise
    /// inherited membership; `false` if the caller was already a direct member
    /// and the call was a no-op.
    public let wasInherited: Bool
    public init(groupId: String, memberPublicKey: String, wasInherited: Bool) {
        self.groupId = groupId; self.memberPublicKey = memberPublicKey; self.wasInherited = wasInherited
    }
}

// MARK: - Context group / storage / sync

/// `ContextGroupResponseData` is `string | null` — surfaced as `String?`.
public typealias ContextGroupResponseData = String?

public struct ContextStorageResponseData: Codable, Sendable {
    public let sizeInBytes: Int
    public init(sizeInBytes: Int) { self.sizeInBytes = sizeInBytes }
}

// MARK: - Specialized Node Invite

public struct InviteSpecializedNodeRequest: Codable, Sendable {
    public var contextId: String
    public var inviterId: String?
    public init(contextId: String, inviterId: String? = nil) { self.contextId = contextId; self.inviterId = inviterId }
}

public struct InviteSpecializedNodeResponseData: Codable, Sendable {
    public let nonce: String
    public init(nonce: String) { self.nonce = nonce }
}

// MARK: - Update Context Application

public struct UpdateContextApplicationRequest: Codable, Sendable {
    public var applicationId: String
    public var executorPublicKey: String
    public init(applicationId: String, executorPublicKey: String) {
        self.applicationId = applicationId; self.executorPublicKey = executorPublicKey
    }
}

// MARK: - Resync Context

public struct ResyncContextRequest: Codable, Sendable {
    /// Force a full re-pull even if the context is not detected as stranded.
    public var force: Bool?
    public init(force: Bool? = nil) { self.force = force }
}

public struct ResyncContextResponseData: Codable, Sendable {
    public let contextId: String
    public let resyncStarted: Bool
    public init(contextId: String, resyncStarted: Bool) {
        self.contextId = contextId; self.resyncStarted = resyncStarted
    }
}

// MARK: - Contexts With Executors

public struct ContextWithExecutors: Codable, Sendable {
    public let contextId: String
    public let executors: [String]
    public init(contextId: String, executors: [String]) { self.contextId = contextId; self.executors = executors }
}

public typealias ContextsWithExecutorsResponseData = [ContextWithExecutors]

// MARK: - Blobs

/// Upload request. `data` is the raw blob bytes, streamed verbatim as the
/// request body (octet-stream) — it is NOT JSON-encoded, so this is a plain
/// (non-Codable) value type.
public struct UploadBlobRequest: Sendable {
    /// Raw blob bytes; streamed verbatim as the request body (octet-stream).
    public var data: Data
    /// Optional expected blob hash; sent as the `hash` query param for server-side verification.
    public var hash: String?
    /// Optional context to announce the blob to; sent as the `context_id` query param.
    public var contextId: String?
    public init(data: Data, hash: String? = nil, contextId: String? = nil) {
        self.data = data; self.hash = hash; self.contextId = contextId
    }
}

public struct BlobInfo: Codable, Sendable {
    public let blobId: String
    public let size: Int
    public init(blobId: String, size: Int) { self.blobId = blobId; self.size = size }
}

public typealias UploadBlobResponseData = BlobInfo

/// QUIRK: core's `BlobDeleteResponse` is a flat, snake_case payload
/// (`{ blob_id, deleted }`) — the lone admin DTO without a camelCase rename and
/// without an inner `data` field. AdminApi decodes it via an internal wire
/// struct and maps to this clean camelCase shape.
public struct DeleteBlobResponseData: Codable, Sendable {
    public let blobId: String
    public let deleted: Bool
    public init(blobId: String, deleted: Bool) { self.blobId = blobId; self.deleted = deleted }
}

public struct ListBlobsResponseData: Codable, Sendable {
    public let blobs: [BlobInfo]
    public init(blobs: [BlobInfo]) { self.blobs = blobs }
}

public typealias GetBlobResponseData = BlobInfo

/// `GetBlobInfoResponseData` extends `BlobInfo` with the extra HEAD-header
/// fields (`x-blob-hash` / `x-blob-mime-type`).
public struct GetBlobInfoResponseData: Codable, Sendable {
    public let blobId: String
    public let size: Int
    public let hash: String?
    public let mimeType: String?
    public init(blobId: String, size: Int, hash: String? = nil, mimeType: String? = nil) {
        self.blobId = blobId; self.size = size; self.hash = hash; self.mimeType = mimeType
    }
}

// MARK: - Aliases

// Core's CreateAliasRequest is `{ alias, #[serde(flatten)] value }`, so each
// alias kind flattens a different id field at the top level of the body.
public struct CreateContextAliasRequest: Codable, Sendable {
    public var alias: String
    public var contextId: String
    public init(alias: String, contextId: String) { self.alias = alias; self.contextId = contextId }
}

public struct CreateApplicationAliasRequest: Codable, Sendable {
    public var alias: String
    public var applicationId: String
    public init(alias: String, applicationId: String) { self.alias = alias; self.applicationId = applicationId }
}

public struct CreateContextIdentityAliasRequest: Codable, Sendable {
    public var alias: String
    public var identity: String
    public init(alias: String, identity: String) { self.alias = alias; self.identity = identity }
}

public struct AliasEntry: Codable, Sendable {
    public let name: String
    public let value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct ListAliasesResponseData: Codable, Sendable {
    public let aliases: [AliasEntry]
    public init(aliases: [AliasEntry]) { self.aliases = aliases }
}

// Create/delete alias returns empty (`Record<string, never>`).
public typealias CreateAliasResponseData = Empty
public typealias DeleteAliasResponseData = Empty

public struct LookupAliasResponseData: Codable, Sendable {
    public let value: String?
    public init(value: String? = nil) { self.value = value }
}

// MARK: - Context identity aliases

public typealias ListContextIdentityAliasesResponseData = ListAliasesResponseData
public typealias CreateContextIdentityAliasResponseData = Empty

public struct LookupContextIdentityAliasResponseData: Codable, Sendable {
    public let value: String?
    public init(value: String? = nil) { self.value = value }
}

public typealias DeleteContextIdentityAliasResponseData = Empty

// MARK: - Shared invitation types

public struct GroupInvitationFromAdmin: Codable, Sendable {
    public var inviterIdentity: [Int]
    public var groupId: [Int]
    public var expirationTimestamp: Int
    public var secretSalt: [Int]
    public var invitedRole: Int?
    public init(
        inviterIdentity: [Int], groupId: [Int], expirationTimestamp: Int, secretSalt: [Int], invitedRole: Int? = nil
    ) {
        self.inviterIdentity = inviterIdentity; self.groupId = groupId
        self.expirationTimestamp = expirationTimestamp; self.secretSalt = secretSalt; self.invitedRole = invitedRole
    }
    enum CodingKeys: String, CodingKey {
        case inviterIdentity = "inviter_identity"
        case groupId = "group_id"
        case expirationTimestamp = "expiration_timestamp"
        case secretSalt = "secret_salt"
        case invitedRole = "invited_role"
    }
}

public struct SignedGroupOpenInvitation: Codable, Sendable {
    public var invitation: GroupInvitationFromAdmin
    public var inviterSignature: String
    public init(invitation: GroupInvitationFromAdmin, inviterSignature: String) {
        self.invitation = invitation; self.inviterSignature = inviterSignature
    }
    // core serializes this type snake_case (it lives in calimero_context_config,
    // which has no rename_all), unlike the camelCase admin DTOs.
    enum CodingKeys: String, CodingKey {
        case invitation
        case inviterSignature = "inviter_signature"
    }
}

public struct RecursiveInvitationEntry: Codable, Sendable {
    public let groupId: String
    public let invitation: SignedGroupOpenInvitation
    public let groupName: String?
    public init(groupId: String, invitation: SignedGroupOpenInvitation, groupName: String? = nil) {
        self.groupId = groupId; self.invitation = invitation; self.groupName = groupName
    }
}

// MARK: - Namespaces

public struct Namespace: Codable, Sendable {
    public let namespaceId: String
    public let appKey: String
    public let targetApplicationId: String
    public let upgradePolicy: String
    public let createdAt: Int
    public let name: String?
    public let memberCount: Int
    public let contextCount: Int
    public let subgroupCount: Int
    public init(
        namespaceId: String, appKey: String, targetApplicationId: String, upgradePolicy: String, createdAt: Int,
        name: String? = nil, memberCount: Int, contextCount: Int, subgroupCount: Int
    ) {
        self.namespaceId = namespaceId; self.appKey = appKey; self.targetApplicationId = targetApplicationId
        self.upgradePolicy = upgradePolicy; self.createdAt = createdAt; self.name = name
        self.memberCount = memberCount; self.contextCount = contextCount; self.subgroupCount = subgroupCount
    }
}

public typealias ListNamespacesResponseData = [Namespace]

public struct NamespaceIdentity: Codable, Sendable {
    public let namespaceId: String
    public let publicKey: String
    public init(namespaceId: String, publicKey: String) { self.namespaceId = namespaceId; self.publicKey = publicKey }
}

/// Core's `UpgradePolicy` enum — how a namespace/group adopts new app versions.
public enum UpgradePolicy: String, Codable, Sendable {
    case automatic = "Automatic"
    case lazyOnAccess = "LazyOnAccess"
}

public struct CreateNamespaceRequest: Codable, Sendable {
    public var applicationId: String
    public var upgradePolicy: UpgradePolicy
    public var name: String?
    /// Hex 32-byte blob id; pins the namespace to a specific installed version.
    public var appKey: String?
    public init(applicationId: String, upgradePolicy: UpgradePolicy, name: String? = nil, appKey: String? = nil) {
        self.applicationId = applicationId; self.upgradePolicy = upgradePolicy; self.name = name; self.appKey = appKey
    }
}

public struct CreateNamespaceResponseData: Codable, Sendable {
    public let namespaceId: String
    public init(namespaceId: String) { self.namespaceId = namespaceId }
}

public struct DeleteNamespaceRequest: Codable, Sendable {
    public var requester: String?
    public init(requester: String? = nil) { self.requester = requester }
}

public struct DeleteNamespaceResponseData: Codable, Sendable {
    public let isDeleted: Bool
    public init(isDeleted: Bool) { self.isDeleted = isDeleted }
}

public struct CreateNamespaceInvitationRequest: Codable, Sendable {
    public var requester: String?
    public var expirationTimestamp: Int?
    public var recursive: Bool?
    public init(requester: String? = nil, expirationTimestamp: Int? = nil, recursive: Bool? = nil) {
        self.requester = requester; self.expirationTimestamp = expirationTimestamp; self.recursive = recursive
    }
}

public struct CreateNamespaceInvitationResponseData: Codable, Sendable {
    public let invitation: SignedGroupOpenInvitation
    public let groupName: String?
    public init(invitation: SignedGroupOpenInvitation, groupName: String? = nil) {
        self.invitation = invitation; self.groupName = groupName
    }
}

public struct CreateRecursiveInvitationResponseData: Codable, Sendable {
    public let invitations: [RecursiveInvitationEntry]
    public init(invitations: [RecursiveInvitationEntry]) { self.invitations = invitations }
}

/// `createNamespaceInvitation` returns one of two shapes depending on whether
/// the invitation was recursive. Modeled as an either-enum with a lenient
/// decode (recursive payloads carry `invitations`; single ones carry
/// `invitation`).
public enum CreateNamespaceInvitationResult: Codable, Sendable {
    case single(CreateNamespaceInvitationResponseData)
    case recursive(CreateRecursiveInvitationResponseData)

    public init(from decoder: Decoder) throws {
        if let r = try? CreateRecursiveInvitationResponseData(from: decoder) {
            self = .recursive(r)
        } else {
            self = .single(try CreateNamespaceInvitationResponseData(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .single(let v): try v.encode(to: encoder)
        case .recursive(let v): try v.encode(to: encoder)
        }
    }
}

public struct JoinNamespaceRequest: Codable, Sendable {
    public var invitation: SignedGroupOpenInvitation
    public var groupName: String?
    public init(invitation: SignedGroupOpenInvitation, groupName: String? = nil) {
        self.invitation = invitation; self.groupName = groupName
    }
}

public struct JoinNamespaceResponseData: Codable, Sendable {
    public let groupId: String
    public let memberIdentity: String
    public let governanceOp: String
    public init(groupId: String, memberIdentity: String, governanceOp: String) {
        self.groupId = groupId; self.memberIdentity = memberIdentity; self.governanceOp = governanceOp
    }
}

public struct CreateGroupInNamespaceRequest: Codable, Sendable {
    public var groupId: String?
    public var name: String?
    public init(groupId: String? = nil, name: String? = nil) { self.groupId = groupId; self.name = name }
}

public struct CreateGroupInNamespaceResponseData: Codable, Sendable {
    public let groupId: String
    public init(groupId: String) { self.groupId = groupId }
}

public struct SubgroupEntry: Codable, Sendable {
    public let groupId: String
    public let name: String?
    public init(groupId: String, name: String? = nil) { self.groupId = groupId; self.name = name }
}

// MARK: - Groups

public struct CreateGroupRequest: Codable, Sendable {
    public var applicationId: String
    public var upgradePolicy: String
    public var groupId: String?
    public var appKey: String?
    public var name: String?
    public var parentGroupId: String?
    public init(
        applicationId: String, upgradePolicy: String, groupId: String? = nil, appKey: String? = nil,
        name: String? = nil, parentGroupId: String? = nil
    ) {
        self.applicationId = applicationId; self.upgradePolicy = upgradePolicy; self.groupId = groupId
        self.appKey = appKey; self.name = name; self.parentGroupId = parentGroupId
    }
}

public struct CreateGroupResponseData: Codable, Sendable {
    public let groupId: String
    public init(groupId: String) { self.groupId = groupId }
}

public struct GroupUpgradeStatus: Codable, Sendable {
    public let fromVersion: String
    public let toVersion: String
    public let initiatedAt: Int
    public let initiatedBy: String
    public let status: String
    public let total: Int?
    public let completed: Int?
    public let failed: Int?
    public let completedAt: Int?
    public init(
        fromVersion: String, toVersion: String, initiatedAt: Int, initiatedBy: String, status: String,
        total: Int? = nil, completed: Int? = nil, failed: Int? = nil, completedAt: Int? = nil
    ) {
        self.fromVersion = fromVersion; self.toVersion = toVersion; self.initiatedAt = initiatedAt
        self.initiatedBy = initiatedBy; self.status = status; self.total = total
        self.completed = completed; self.failed = failed; self.completedAt = completedAt
    }
}

// MARK: - Migration status (migration-UX core surfaces)

public enum MemberMigrationState: String, Codable, Sendable {
    case migrated
    case inProgress = "in_progress"
    case unknown
    case failed
}

/// Why a member's migration did not complete.
public enum MigrationFailureReason: String, Codable, Sendable {
    case checkAborted = "check_aborted"
    case applyFailed = "apply_failed"
    case noMigrationPath = "no_migration_path"
}

public struct MemberMigrationReport: Codable, Sendable {
    public let schemaVersion: Int
    public let residueAuto: Int
    public let residueIdentity: Int
    public let syncedUpToHlc: Int
    public let reportedAt: Int
    /// Member's self-reported pending-authored count (best-effort; skew #1).
    public let authoredRemaining: Int
    /// Set when the member's migrate did not complete (its migration-check
    /// aborted, or the apply errored). Absent otherwise.
    public let migrationFailed: MigrationFailureReason?
    public init(
        schemaVersion: Int, residueAuto: Int, residueIdentity: Int, syncedUpToHlc: Int, reportedAt: Int,
        authoredRemaining: Int, migrationFailed: MigrationFailureReason? = nil
    ) {
        self.schemaVersion = schemaVersion; self.residueAuto = residueAuto; self.residueIdentity = residueIdentity
        self.syncedUpToHlc = syncedUpToHlc; self.reportedAt = reportedAt
        self.authoredRemaining = authoredRemaining; self.migrationFailed = migrationFailed
    }
}

public struct MemberMigrationStatusEntry: Codable, Sendable {
    public let peer: String
    /// Freshest reported facts, or `null` when the member's state is `unknown`.
    public let report: MemberMigrationReport?
    public let state: MemberMigrationState
    public init(peer: String, report: MemberMigrationReport?, state: MemberMigrationState) {
        self.peer = peer; self.report = report; self.state = state
    }
}

public struct MigrationStatusRollup: Codable, Sendable {
    public let migrated: Int
    public let inProgress: Int
    public let unknown: Int
    /// Members whose migrate aborted (migration-check failed or apply errored).
    public let failed: Int
    public let total: Int
    public let allMigrated: Bool
    /// Count of members with authoredRemaining > 0 (owners still to re-sign).
    public let membersPendingSignature: Int
    public init(
        migrated: Int, inProgress: Int, unknown: Int, failed: Int, total: Int, allMigrated: Bool,
        membersPendingSignature: Int
    ) {
        self.migrated = migrated; self.inProgress = inProgress; self.unknown = unknown; self.failed = failed
        self.total = total; self.allMigrated = allMigrated; self.membersPendingSignature = membersPendingSignature
    }
}

public struct MigrationStatus: Codable, Sendable {
    public let targetVersion: Int
    public let expectedMembers: Int
    public let cohortPinnedAtHlc: String?
    public let rollup: MigrationStatusRollup
    public let members: [MemberMigrationStatusEntry]
    public init(
        targetVersion: Int, expectedMembers: Int, cohortPinnedAtHlc: String? = nil,
        rollup: MigrationStatusRollup, members: [MemberMigrationStatusEntry]
    ) {
        self.targetVersion = targetVersion; self.expectedMembers = expectedMembers
        self.cohortPinnedAtHlc = cohortPinnedAtHlc; self.rollup = rollup; self.members = members
    }
}

// MARK: - Cascade status

public struct CascadeStatusEntry: Codable, Sendable {
    public let groupId: String
    public let upgrade: GroupUpgradeStatus
    public let cascadeHlc: String?
    public init(groupId: String, upgrade: GroupUpgradeStatus, cascadeHlc: String? = nil) {
        self.groupId = groupId; self.upgrade = upgrade; self.cascadeHlc = cascadeHlc
    }
}

public struct GroupInfo: Codable, Sendable {
    public let groupId: String
    public let appKey: String
    public let targetApplicationId: String
    public let upgradePolicy: String
    public let memberCount: Int
    public let contextCount: Int
    public let activeUpgrade: GroupUpgradeStatus?
    public let defaultCapabilities: Int
    public let subgroupVisibility: String
    /// The group's generic metadata record (replaces the old `alias` field).
    /// `null` if no metadata has ever been set for this group.
    public let metadata: MetadataRecord?
    public init(
        groupId: String, appKey: String, targetApplicationId: String, upgradePolicy: String,
        memberCount: Int, contextCount: Int, activeUpgrade: GroupUpgradeStatus? = nil,
        defaultCapabilities: Int, subgroupVisibility: String, metadata: MetadataRecord? = nil
    ) {
        self.groupId = groupId; self.appKey = appKey; self.targetApplicationId = targetApplicationId
        self.upgradePolicy = upgradePolicy; self.memberCount = memberCount; self.contextCount = contextCount
        self.activeUpgrade = activeUpgrade; self.defaultCapabilities = defaultCapabilities
        self.subgroupVisibility = subgroupVisibility; self.metadata = metadata
    }
}

public typealias GroupInfoResponseData = GroupInfo

public struct GroupMember: Codable, Sendable {
    public let identity: String
    public let role: String
    public let name: String?
    public init(identity: String, role: String, name: String? = nil) {
        self.identity = identity; self.role = role; self.name = name
    }
}

public struct ListGroupMembersResponseData: Codable, Sendable {
    public let members: [GroupMember]
    public let selfIdentity: String?
    /// @deprecated The server response uses `members`, not `data`. This alias is
    /// retained for parity with the TS type; it is never populated by the
    /// client. Switch reads to `members`.
    public let data: [GroupMember]?
    public init(members: [GroupMember], selfIdentity: String? = nil, data: [GroupMember]? = nil) {
        self.members = members; self.selfIdentity = selfIdentity; self.data = data
    }
}

public struct GroupContextEntry: Codable, Sendable {
    public let contextId: String
    public let name: String?
    public init(contextId: String, name: String? = nil) { self.contextId = contextId; self.name = name }
}

public typealias ListGroupContextsResponseData = [GroupContextEntry]

public struct DeleteGroupRequest: Codable, Sendable {
    public var requester: String?
    public init(requester: String? = nil) { self.requester = requester }
}

public struct DeleteGroupResponseData: Codable, Sendable {
    public let isDeleted: Bool
    public init(isDeleted: Bool) { self.isDeleted = isDeleted }
}

// MARK: - Group Members

public struct GroupMemberInput: Codable, Sendable {
    public var identity: String
    public var role: String
    public init(identity: String, role: String) { self.identity = identity; self.role = role }
}

public struct AddGroupMembersRequest: Codable, Sendable {
    public var members: [GroupMemberInput]
    public var requester: String?
    public init(members: [GroupMemberInput], requester: String? = nil) {
        self.members = members; self.requester = requester
    }
}

public struct RemoveGroupMembersRequest: Codable, Sendable {
    public var members: [String]
    public var requester: String?
    public init(members: [String], requester: String? = nil) { self.members = members; self.requester = requester }
}

public struct UpdateMemberRoleRequest: Codable, Sendable {
    public var role: String
    public var requester: String?
    public init(role: String, requester: String? = nil) { self.role = role; self.requester = requester }
}

// MARK: - Group Capabilities & Settings

public struct MemberCapabilities: Codable, Sendable {
    public let capabilities: Int
    public init(capabilities: Int) { self.capabilities = capabilities }
}

public struct SetMemberCapabilitiesRequest: Codable, Sendable {
    public var capabilities: Int
    public var requester: String?
    public init(capabilities: Int, requester: String? = nil) {
        self.capabilities = capabilities; self.requester = requester
    }
}

public struct SetDefaultCapabilitiesRequest: Codable, Sendable {
    public var defaultCapabilities: Int
    public var requester: String?
    public init(defaultCapabilities: Int, requester: String? = nil) {
        self.defaultCapabilities = defaultCapabilities; self.requester = requester
    }
}

public struct SetSubgroupVisibilityRequest: Codable, Sendable {
    public var subgroupVisibility: String
    public var requester: String?
    public init(subgroupVisibility: String, requester: String? = nil) {
        self.subgroupVisibility = subgroupVisibility; self.requester = requester
    }
}

public struct SetTeeAdmissionPolicyRequest: Codable, Sendable {
    public var allowedMrtd: [String]
    public var allowedRtmr0: [String]
    public var allowedRtmr1: [String]
    public var allowedRtmr2: [String]
    public var allowedRtmr3: [String]
    public var allowedTcbStatuses: [String]
    public var acceptMock: Bool
    public var requester: String?
    public init(
        allowedMrtd: [String], allowedRtmr0: [String], allowedRtmr1: [String], allowedRtmr2: [String],
        allowedRtmr3: [String], allowedTcbStatuses: [String], acceptMock: Bool, requester: String? = nil
    ) {
        self.allowedMrtd = allowedMrtd; self.allowedRtmr0 = allowedRtmr0; self.allowedRtmr1 = allowedRtmr1
        self.allowedRtmr2 = allowedRtmr2; self.allowedRtmr3 = allowedRtmr3
        self.allowedTcbStatuses = allowedTcbStatuses; self.acceptMock = acceptMock; self.requester = requester
    }
}

public struct GetTeeAdmissionPolicyResponseData: Codable, Sendable {
    public let allowedMrtd: [String]
    public let allowedRtmr0: [String]
    public let allowedRtmr1: [String]
    public let allowedRtmr2: [String]
    public let allowedRtmr3: [String]
    public let allowedTcbStatuses: [String]
    public let acceptMock: Bool
    public init(
        allowedMrtd: [String], allowedRtmr0: [String], allowedRtmr1: [String], allowedRtmr2: [String],
        allowedRtmr3: [String], allowedTcbStatuses: [String], acceptMock: Bool
    ) {
        self.allowedMrtd = allowedMrtd; self.allowedRtmr0 = allowedRtmr0; self.allowedRtmr1 = allowedRtmr1
        self.allowedRtmr2 = allowedRtmr2; self.allowedRtmr3 = allowedRtmr3
        self.allowedTcbStatuses = allowedTcbStatuses; self.acceptMock = acceptMock
    }
}

public struct UpdateGroupSettingsRequest: Codable, Sendable {
    public var upgradePolicy: String
    public var requester: String?
    public init(upgradePolicy: String, requester: String? = nil) {
        self.upgradePolicy = upgradePolicy; self.requester = requester
    }
}

// MARK: - Group / member / context metadata

/// Generic metadata record attached to a group, group member, or
/// context-registered-in-a-group (core `calimero_primitives::metadata::MetadataRecord`).
///
/// `data` is application-defined and opaque to core — it is stored verbatim.
/// Server-enforced size limits: `name` <= 64 bytes; at most 64 entries in
/// `data`; each key <= 64 bytes; each value <= 4096 bytes. Clients do not need
/// to enforce these — the server validates.
public struct MetadataRecord: Codable, Sendable {
    public let name: String?
    public let data: [String: String]
    public let updatedAt: Int
    /// Public key (hex) of the member that last updated the record.
    public let updatedBy: String
    public init(name: String?, data: [String: String], updatedAt: Int, updatedBy: String) {
        self.name = name; self.data = data; self.updatedAt = updatedAt; self.updatedBy = updatedBy
    }
}

/// Request body for setting a metadata record. **This wholly replaces the
/// record**: `data` defaults to `{}` server-side and replaces the stored map,
/// while omitting `name` keeps the current name. To change `name` while
/// preserving existing `data`, GET the record first and pass its `data` back.
public struct SetMetadataRequest: Codable, Sendable {
    public var name: String?
    public var data: [String: String]?
    public var requester: String?
    public init(name: String? = nil, data: [String: String]? = nil, requester: String? = nil) {
        self.name = name; self.data = data; self.requester = requester
    }
}

public typealias SetGroupMetadataRequest = SetMetadataRequest
public typealias SetMemberMetadataRequest = SetMetadataRequest
public typealias SetContextMetadataRequest = SetMetadataRequest

/// Inner payload of a GET metadata response. `data` is `null` if no metadata
/// has ever been set for the target group/member/context.
public struct GetMetadataResponseData: Codable, Sendable {
    public let data: MetadataRecord?
    public init(data: MetadataRecord?) { self.data = data }
}

// MARK: - Group Sync, Signing & Upgrades

public struct SyncGroupRequest: Codable, Sendable {
    public var requester: String?
    public init(requester: String? = nil) { self.requester = requester }
}

public struct SyncGroupResponseData: Codable, Sendable {
    public let groupId: String
    public let appKey: String
    public let targetApplicationId: String
    public let memberCount: Int
    public let contextCount: Int
    public init(groupId: String, appKey: String, targetApplicationId: String, memberCount: Int, contextCount: Int) {
        self.groupId = groupId; self.appKey = appKey; self.targetApplicationId = targetApplicationId
        self.memberCount = memberCount; self.contextCount = contextCount
    }
}

public struct RegisterGroupSigningKeyRequest: Codable, Sendable {
    public var signingKey: String
    public init(signingKey: String) { self.signingKey = signingKey }
}

public struct RegisterGroupSigningKeyResponseData: Codable, Sendable {
    public let publicKey: String
    public init(publicKey: String) { self.publicKey = publicKey }
}

public struct UpgradeGroupRequest: Codable, Sendable {
    public var targetApplicationId: String
    public var requester: String?
    /// Fan the upgrade out to every descendant subgroup running the same app
    /// (one atomic cascade op). Without it the upgrade applies to the target
    /// group only — members' subgroups never learn the migration. Server
    /// default: false.
    public var cascade: Bool?
    public init(targetApplicationId: String, requester: String? = nil, cascade: Bool? = nil) {
        self.targetApplicationId = targetApplicationId; self.requester = requester; self.cascade = cascade
    }
}

public struct UpgradeGroupResponseData: Codable, Sendable {
    public let groupId: String
    public let status: String
    public let total: Int?
    public let completed: Int?
    public let failed: Int?
    public init(groupId: String, status: String, total: Int? = nil, completed: Int? = nil, failed: Int? = nil) {
        self.groupId = groupId; self.status = status; self.total = total; self.completed = completed
        self.failed = failed
    }
}

/// `GroupUpgradeStatusResponseData` is `GroupUpgradeStatus | null`.
public typealias GroupUpgradeStatusResponseData = GroupUpgradeStatus?

public struct RetryGroupUpgradeRequest: Codable, Sendable {
    public var requester: String?
    public init(requester: String? = nil) { self.requester = requester }
}

/// Retry returns the same shape as upgrade.
public typealias RetryGroupUpgradeResponseData = UpgradeGroupResponseData

// MARK: - Group Reparent & Context Attachments

public struct ReparentGroupRequest: Codable, Sendable {
    /// 64-char id of the destination parent group.
    public var newParentId: String
    public var requester: String?
    public init(newParentId: String, requester: String? = nil) {
        self.newParentId = newParentId; self.requester = requester
    }
}

public struct ReparentGroupResponseData: Codable, Sendable {
    public let reparented: Bool
    public init(reparented: Bool) { self.reparented = reparented }
}

public struct DetachContextFromGroupRequest: Codable, Sendable {
    public var requester: String?
    public init(requester: String? = nil) { self.requester = requester }
}

// MARK: - Group Invitation & Join

public struct CreateGroupInvitationRequest: Codable, Sendable {
    public var requester: String?
    public var expirationTimestamp: Int?
    public var recursive: Bool?
    public init(requester: String? = nil, expirationTimestamp: Int? = nil, recursive: Bool? = nil) {
        self.requester = requester; self.expirationTimestamp = expirationTimestamp; self.recursive = recursive
    }
}

public struct CreateGroupInvitationResponseData: Codable, Sendable {
    public let invitation: SignedGroupOpenInvitation
    public let groupName: String?
    public init(invitation: SignedGroupOpenInvitation, groupName: String? = nil) {
        self.invitation = invitation; self.groupName = groupName
    }
}

public struct CreateRecursiveGroupInvitationResponseData: Codable, Sendable {
    public let invitations: [RecursiveInvitationEntry]
    public init(invitations: [RecursiveInvitationEntry]) { self.invitations = invitations }
}

/// `createGroupInvitation` returns one of two shapes (single vs recursive).
/// Same either-enum treatment as `CreateNamespaceInvitationResult`.
public enum CreateGroupInvitationResult: Codable, Sendable {
    case single(CreateGroupInvitationResponseData)
    case recursive(CreateRecursiveGroupInvitationResponseData)

    public init(from decoder: Decoder) throws {
        if let r = try? CreateRecursiveGroupInvitationResponseData(from: decoder) {
            self = .recursive(r)
        } else {
            self = .single(try CreateGroupInvitationResponseData(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .single(let v): try v.encode(to: encoder)
        case .recursive(let v): try v.encode(to: encoder)
        }
    }
}

public struct JoinGroupRequest: Codable, Sendable {
    public var invitation: SignedGroupOpenInvitation
    public var groupName: String?
    public init(invitation: SignedGroupOpenInvitation, groupName: String? = nil) {
        self.invitation = invitation; self.groupName = groupName
    }
}

public struct JoinGroupResponseData: Codable, Sendable {
    public let groupId: String
    public let memberIdentity: String
    public let governanceOp: String
    public init(groupId: String, memberIdentity: String, governanceOp: String) {
        self.groupId = groupId; self.memberIdentity = memberIdentity; self.governanceOp = governanceOp
    }
}

// MARK: - TEE

public struct TeeInfoResponseData: Codable, Sendable {
    public let cloudProvider: String
    public let osImage: String
    public let mrtd: String
    public init(cloudProvider: String, osImage: String, mrtd: String) {
        self.cloudProvider = cloudProvider; self.osImage = osImage; self.mrtd = mrtd
    }
}

public struct TeeAttestRequest: Codable, Sendable {
    public var nonce: String
    public var applicationId: String?
    public init(nonce: String, applicationId: String? = nil) { self.nonce = nonce; self.applicationId = applicationId }
}

public struct QuoteHeader: Codable, Sendable {
    public let version: Int
    public let attestationKeyType: Int
    public let teeType: Int
    public let qeVendorId: String
    public let userData: String
    public init(version: Int, attestationKeyType: Int, teeType: Int, qeVendorId: String, userData: String) {
        self.version = version; self.attestationKeyType = attestationKeyType; self.teeType = teeType
        self.qeVendorId = qeVendorId; self.userData = userData
    }
}

public struct QuoteBody: Codable, Sendable {
    public let tdxVersion: String
    public let teeTcbSvn: String
    public let mrseam: String
    public let mrsignerseam: String
    public let seamattributes: String
    public let tdattributes: String
    public let xfam: String
    public let mrtd: String
    public let mrconfigid: String
    public let mrowner: String
    public let mrownerconfig: String
    public let rtmr0: String
    public let rtmr1: String
    public let rtmr2: String
    public let rtmr3: String
    public let reportdata: String
    public let teeTcbSvn2: String?
    public let mrservicetd: String?
    public init(
        tdxVersion: String, teeTcbSvn: String, mrseam: String, mrsignerseam: String, seamattributes: String,
        tdattributes: String, xfam: String, mrtd: String, mrconfigid: String, mrowner: String,
        mrownerconfig: String, rtmr0: String, rtmr1: String, rtmr2: String, rtmr3: String, reportdata: String,
        teeTcbSvn2: String? = nil, mrservicetd: String? = nil
    ) {
        self.tdxVersion = tdxVersion; self.teeTcbSvn = teeTcbSvn; self.mrseam = mrseam; self.mrsignerseam = mrsignerseam
        self.seamattributes = seamattributes; self.tdattributes = tdattributes; self.xfam = xfam; self.mrtd = mrtd
        self.mrconfigid = mrconfigid; self.mrowner = mrowner; self.mrownerconfig = mrownerconfig
        self.rtmr0 = rtmr0; self.rtmr1 = rtmr1; self.rtmr2 = rtmr2; self.rtmr3 = rtmr3; self.reportdata = reportdata
        self.teeTcbSvn2 = teeTcbSvn2; self.mrservicetd = mrservicetd
    }
}

public struct Quote: Codable, Sendable {
    public let header: QuoteHeader
    public let body: QuoteBody
    public let signature: String
    public let attestationKey: String
    /// `unknown` in the TS — arbitrary JSON. Modeled optional to tolerate omission.
    public let certificationData: JSONValue?
    public init(
        header: QuoteHeader, body: QuoteBody, signature: String, attestationKey: String,
        certificationData: JSONValue? = nil
    ) {
        self.header = header; self.body = body; self.signature = signature
        self.attestationKey = attestationKey; self.certificationData = certificationData
    }
}

public struct TeeAttestResponseData: Codable, Sendable {
    public let quoteB64: String
    public let quote: Quote
    public init(quoteB64: String, quote: Quote) { self.quoteB64 = quoteB64; self.quote = quote }
}

public struct TeeVerifyQuoteRequest: Codable, Sendable {
    public var quoteB64: String
    public var nonce: String
    public var expectedApplicationHash: String?
    public init(quoteB64: String, nonce: String, expectedApplicationHash: String? = nil) {
        self.quoteB64 = quoteB64; self.nonce = nonce; self.expectedApplicationHash = expectedApplicationHash
    }
}

public struct TeeVerifyQuoteResponseData: Codable, Sendable {
    public let quoteVerified: Bool
    public let nonceVerified: Bool
    public let applicationHashVerified: Bool?
    public let quote: Quote
    public init(quoteVerified: Bool, nonceVerified: Bool, applicationHashVerified: Bool? = nil, quote: Quote) {
        self.quoteVerified = quoteVerified; self.nonceVerified = nonceVerified
        self.applicationHashVerified = applicationHashVerified; self.quote = quote
    }
}

// MARK: - Network

public struct PeersCountResponseData: Codable, Sendable {
    public let count: Int
    public init(count: Int) { self.count = count }
}
