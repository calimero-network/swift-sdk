import Foundation
import MeroKit

// The complete SDK surface, one `SDKOperation` per public method. Split into
// per-category arrays so the Swift type-checker stays fast. Request bodies are
// entered as JSON and decoded into the typed request; results are pretty-printed.

// MARK: Health & Node

private let healthOps: [SDKOperation] = [
    SDKOperation(id: "adm.health", category: "Health & Node", name: "healthCheck",
                 summary: "Node liveness", fields: []) { m, _ in Fmt.json(try await m.admin.healthCheck()) },
    SDKOperation(id: "adm.isAuthed", category: "Health & Node", name: "isAuthed",
                 summary: "Admin auth status", fields: []) { m, _ in Fmt.json(try await m.admin.isAuthed()) },
    SDKOperation(id: "adm.peers", category: "Health & Node", name: "getPeersCount",
                 summary: "Connected peer count", fields: []) { m, _ in Fmt.json(try await m.admin.getPeersCount()) },
    SDKOperation(id: "adm.net", category: "Health & Node", name: "getNetworkStatus",
                 summary: "Network status", fields: []) { m, _ in Fmt.json(try await m.admin.getNetworkStatus()) },
    SDKOperation(id: "adm.usage", category: "Health & Node", name: "getUsage",
                 summary: "Storage / usage stats", fields: []) { m, _ in Fmt.json(try await m.admin.getUsage()) },
    SDKOperation(id: "adm.cert", category: "Health & Node", name: "getCertificate",
                 summary: "Node TLS certificate (PEM)", fields: []) { m, _ in try await m.admin.getCertificate() },
]

// MARK: Auth & Identity

private let authOps: [SDKOperation] = [
    SDKOperation(id: "auth.health", category: "Auth & Identity", name: "getHealth",
                 summary: "Auth service health", fields: []) { m, _ in Fmt.json(try await m.auth.getHealth()) },
    SDKOperation(id: "auth.identity", category: "Auth & Identity", name: "getIdentity",
                 summary: "Service / version / providers", fields: []) { m, _ in Fmt.json(try await m.auth.getIdentity()) },
    SDKOperation(id: "auth.providers", category: "Auth & Identity", name: "getProviders",
                 summary: "Available auth providers", fields: []) { m, _ in Fmt.json(try await m.auth.getProviders()) },
    SDKOperation(id: "auth.gen", category: "Auth & Identity", name: "generateTokens",
                 summary: "Mint tokens from a challenge", fields: [.json()]) { m, i in
        Fmt.json(try await m.auth.generateTokens(try Fmt.decode(i.v("body"), TokenRequest.self)))
    },
    SDKOperation(id: "auth.refresh", category: "Auth & Identity", name: "refreshToken",
                 summary: "Refresh an access token", fields: [.json()]) { m, i in
        Fmt.json(try await m.auth.refreshToken(try Fmt.decode(i.v("body"), RefreshTokenRequest.self)))
    },
    SDKOperation(id: "auth.mock", category: "Auth & Identity", name: "generateMockTokens",
                 summary: "Mint mock tokens (dev nodes)", fields: [.json()]) { m, i in
        Fmt.json(try await m.auth.generateMockTokens(try Fmt.decode(i.v("body"), MockTokenRequest.self)))
    },
    SDKOperation(id: "auth.validate", category: "Auth & Identity", name: "validateToken",
                 summary: "HEAD /auth/validate", fields: [.line("token", "Access token")]) { m, i in
        let val = await m.auth.validateToken(i.v("token"))
        return "valid: \(val.valid)\nstatus: \(val.status)\nheaders:\n\(Fmt.json(val.headers))"
    },
    SDKOperation(id: "auth.revoke", category: "Auth & Identity", name: "revokeTokens",
                 summary: "Revoke a token family", fields: [.json()]) { m, i in
        Fmt.json(try await m.auth.revokeTokens(try Fmt.decode(i.v("body"), RevokeTokenRequest.self)))
    },
]

// MARK: Root & Client Keys

private let keyOps: [SDKOperation] = [
    SDKOperation(id: "key.rootList", category: "Root & Client Keys", name: "listRootKeys",
                 summary: "All root keys", fields: []) { m, _ in Fmt.json(try await m.auth.listRootKeys()) },
    SDKOperation(id: "key.rootCreate", category: "Root & Client Keys", name: "createRootKey",
                 summary: "Register a root key", fields: [.json()]) { m, i in
        Fmt.json(try await m.auth.createRootKey(try Fmt.decode(i.v("body"), CreateKeyRequest.self)))
    },
    SDKOperation(id: "key.rootDelete", category: "Root & Client Keys", name: "deleteRootKey",
                 summary: "Delete a root key", fields: [.line("keyId", "Key ID")]) { m, i in
        Fmt.json(try await m.auth.deleteRootKey(i.v("keyId")))
    },
    SDKOperation(id: "key.clientList", category: "Root & Client Keys", name: "listClientKeys",
                 summary: "All client keys", fields: []) { m, _ in Fmt.json(try await m.auth.listClientKeys()) },
    SDKOperation(id: "key.clientGen", category: "Root & Client Keys", name: "generateClientKey",
                 summary: "Issue a client key", fields: [.json()]) { m, i in
        Fmt.json(try await m.auth.generateClientKey(try Fmt.decode(i.v("body"), GenerateClientKeyRequest.self)))
    },
    SDKOperation(id: "key.clientDelete", category: "Root & Client Keys", name: "deleteClientKey",
                 summary: "Delete a client key", fields: [.line("keyId", "Key ID"), .line("clientId", "Client ID")]) { m, i in
        Fmt.json(try await m.auth.deleteClientKey(keyId: i.v("keyId"), clientId: i.v("clientId")))
    },
    SDKOperation(id: "key.perms", category: "Root & Client Keys", name: "getKeyPermissions",
                 summary: "Key permissions", fields: [.line("keyId", "Key ID")]) { m, i in
        Fmt.json(try await m.auth.getKeyPermissions(i.v("keyId")))
    },
    SDKOperation(id: "key.permsUpdate", category: "Root & Client Keys", name: "updateKeyPermissions",
                 summary: "Add/remove key permissions",
                 fields: [.line("keyId", "Key ID"), .json("body", "Changes", "{\"add\":[],\"remove\":[]}")]) { m, i in
        Fmt.json(try await m.auth.updateKeyPermissions(i.v("keyId"), changes: try Fmt.decode(i.v("body"), UpdateKeyPermissionsRequest.self)))
    },
]

// MARK: Applications

private let appOps: [SDKOperation] = [
    SDKOperation(id: "app.list", category: "Applications", name: "listApplications",
                 summary: "Installed applications", fields: []) { m, _ in Fmt.json(try await m.admin.listApplications()) },
    SDKOperation(id: "app.get", category: "Applications", name: "getApplication",
                 summary: "One application", fields: [.line("appId", "Application ID")]) { m, i in
        Fmt.json(try await m.admin.getApplication(i.v("appId")))
    },
    SDKOperation(id: "app.install", category: "Applications", name: "installApplication",
                 summary: "Install by URL", fields: [.json()]) { m, i in
        Fmt.json(try await m.admin.installApplication(try Fmt.decode(i.v("body"), InstallApplicationRequest.self)))
    },
    SDKOperation(id: "app.installDev", category: "Applications", name: "installDevApplication",
                 summary: "Install a local dev bundle", fields: [.json()]) { m, i in
        Fmt.json(try await m.admin.installDevApplication(try Fmt.decode(i.v("body"), InstallDevApplicationRequest.self)))
    },
    SDKOperation(id: "app.uninstall", category: "Applications", name: "uninstallApplication",
                 summary: "Uninstall", fields: [.line("appId", "Application ID")]) { m, i in
        Fmt.json(try await m.admin.uninstallApplication(i.v("appId")))
    },
    SDKOperation(id: "app.versions", category: "Applications", name: "listApplicationVersions",
                 summary: "Installed versions", fields: [.line("appId", "Application ID")]) { m, i in
        Fmt.json(try await m.admin.listApplicationVersions(i.v("appId")))
    },
    SDKOperation(id: "app.ctxFor", category: "Applications", name: "getContextsForApplication",
                 summary: "Contexts for an app", fields: [.line("appId", "Application ID")]) { m, i in
        Fmt.json(try await m.admin.getContextsForApplication(i.v("appId")))
    },
    SDKOperation(id: "app.ctxExec", category: "Applications", name: "getContextsWithExecutorsForApplication",
                 summary: "Contexts + executors for an app", fields: [.line("appId", "Application ID")]) { m, i in
        Fmt.json(try await m.admin.getContextsWithExecutorsForApplication(i.v("appId")))
    },
    SDKOperation(id: "app.nsFor", category: "Applications", name: "listNamespacesForApplication",
                 summary: "Namespaces for an app", fields: [.line("appId", "Application ID")]) { m, i in
        Fmt.json(try await m.admin.listNamespacesForApplication(i.v("appId")))
    },
]

// MARK: Packages & Registry

private let pkgOps: [SDKOperation] = [
    SDKOperation(id: "pkg.list", category: "Packages & Registry", name: "listPackages",
                 summary: "Known packages", fields: []) { m, _ in Fmt.json(try await m.admin.listPackages()) },
    SDKOperation(id: "pkg.versions", category: "Packages & Registry", name: "listPackageVersions",
                 summary: "Installed versions", fields: [.line("packageName", "Package name")]) { m, i in
        Fmt.json(try await m.admin.listPackageVersions(i.v("packageName")))
    },
    SDKOperation(id: "pkg.latest", category: "Packages & Registry", name: "getLatestPackageVersion",
                 summary: "Latest installed version", fields: [.line("packageName", "Package name")]) { m, i in
        Fmt.json(try await m.admin.getLatestPackageVersion(i.v("packageName")))
    },
    SDKOperation(id: "pkg.regVersions", category: "Packages & Registry", name: "getRegistryVersions",
                 summary: "Registry versions (off-node)",
                 fields: [.line("registryUrl", "Registry URL"), .line("packageName", "Package name")]) { m, i in
        Fmt.json(try await m.admin.getRegistryVersions(registryUrl: i.v("registryUrl"), packageName: i.v("packageName")))
    },
    SDKOperation(id: "pkg.install", category: "Packages & Registry", name: "installFromRegistry",
                 summary: "Resolve + install from registry",
                 fields: [.line("registryUrl", "Registry URL"), .line("packageName", "Package"), .line("version", "Version")]) { m, i in
        Fmt.json(try await m.admin.installFromRegistry(registryUrl: i.v("registryUrl"), packageName: i.v("packageName"), version: i.v("version")))
    },
    SDKOperation(id: "pkg.semver", category: "Packages & Registry", name: "compareSemver",
                 summary: "Compare two versions", fields: [.line("a", "Version A"), .line("b", "Version B")]) { _, i in
        "compareSemver(\(i.v("a")), \(i.v("b"))) = \(compareSemver(i.v("a"), i.v("b")))"
    },
]

// MARK: Contexts

private let ctxOps: [SDKOperation] = [
    SDKOperation(id: "ctx.list", category: "Contexts", name: "getContexts",
                 summary: "All contexts", fields: []) { m, _ in Fmt.json(try await m.admin.getContexts()) },
    SDKOperation(id: "ctx.get", category: "Contexts", name: "getContext",
                 summary: "One context", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.getContext(i.v("contextId")))
    },
    SDKOperation(id: "ctx.create", category: "Contexts", name: "createContext",
                 summary: "Create a context", fields: [.json("body", "CreateContextRequest", "{\n  \"applicationId\": \"...\"\n}")]) { m, i in
        Fmt.json(try await m.admin.createContext(try Fmt.decode(i.v("body"), CreateContextRequest.self)))
    },
    SDKOperation(id: "ctx.delete", category: "Contexts", name: "deleteContext",
                 summary: "Delete a context", fields: [.line("contextId", "Context ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: DeleteContextRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), DeleteContextRequest.self) : nil
        return Fmt.json(try await m.admin.deleteContext(i.v("contextId"), request: req))
    },
    SDKOperation(id: "ctx.join", category: "Contexts", name: "joinContext",
                 summary: "Join a context", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.joinContext(i.v("contextId")))
    },
    SDKOperation(id: "ctx.leave", category: "Contexts", name: "leaveContext",
                 summary: "Leave a context", fields: [.line("contextId", "Context ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: [String: JSONValue]? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), [String: JSONValue].self) : nil
        try await m.admin.leaveContext(i.v("contextId"), request: req)
        return "✓ left context"
    },
    SDKOperation(id: "ctx.group", category: "Contexts", name: "getContextGroup",
                 summary: "Owning group (nullable)", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.getContextGroup(i.v("contextId")))
    },
    SDKOperation(id: "ctx.storage", category: "Contexts", name: "getContextStorage",
                 summary: "Context storage stats", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.getContextStorage(i.v("contextId")))
    },
    SDKOperation(id: "ctx.sync", category: "Contexts", name: "syncContext",
                 summary: "Sync one/all contexts", fields: [.line("contextId", "Context ID (blank = all)")]) { m, i in
        try await m.admin.syncContext(i.opt("contextId"))
        return "✓ sync requested"
    },
    SDKOperation(id: "ctx.resync", category: "Contexts", name: "resyncContext",
                 summary: "Force a full re-pull", fields: [.line("contextId", "Context ID"), .json("body", "ResyncContextRequest", "{}")]) { m, i in
        let req = try Fmt.decode(i.v("body"), ResyncContextRequest.self)
        return Fmt.json(try await m.admin.resyncContext(i.v("contextId"), request: req))
    },
    SDKOperation(id: "ctx.updateApp", category: "Contexts", name: "updateContextApplication",
                 summary: "Point a context at a new app", fields: [.line("contextId", "Context ID"), .json("body", "UpdateContextApplicationRequest")]) { m, i in
        try await m.admin.updateContextApplication(i.v("contextId"), request: try Fmt.decode(i.v("body"), UpdateContextApplicationRequest.self))
        return "✓ application updated"
    },
    SDKOperation(id: "ctx.inviteNode", category: "Contexts", name: "inviteSpecializedNode",
                 summary: "Invite a specialized node", fields: [.json()]) { m, i in
        Fmt.json(try await m.admin.inviteSpecializedNode(try Fmt.decode(i.v("body"), InviteSpecializedNodeRequest.self)))
    },
]

// MARK: Context Identity

private let ctxIdOps: [SDKOperation] = [
    SDKOperation(id: "cid.gen", category: "Context Identity", name: "generateContextIdentity",
                 summary: "Generate a context identity", fields: []) { m, _ in
        Fmt.json(try await m.admin.generateContextIdentity())
    },
    SDKOperation(id: "cid.list", category: "Context Identity", name: "getContextIdentities",
                 summary: "All identities in a context", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.getContextIdentities(i.v("contextId")))
    },
    SDKOperation(id: "cid.owned", category: "Context Identity", name: "getContextIdentitiesOwned",
                 summary: "Owned identities in a context", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.getContextIdentitiesOwned(i.v("contextId")))
    },
]

// MARK: Aliases

private let aliasOps: [SDKOperation] = [
    SDKOperation(id: "al.ctxCreate", category: "Aliases", name: "createContextAlias",
                 summary: "Create context alias", fields: [.json()]) { m, i in
        Fmt.json(try await m.admin.createContextAlias(try Fmt.decode(i.v("body"), CreateContextAliasRequest.self)))
    },
    SDKOperation(id: "al.appCreate", category: "Aliases", name: "createApplicationAlias",
                 summary: "Create application alias", fields: [.json()]) { m, i in
        Fmt.json(try await m.admin.createApplicationAlias(try Fmt.decode(i.v("body"), CreateApplicationAliasRequest.self)))
    },
    SDKOperation(id: "al.ctxLookup", category: "Aliases", name: "lookupContextAlias",
                 summary: "Resolve context alias", fields: [.line("name", "Alias name")]) { m, i in
        Fmt.json(try await m.admin.lookupContextAlias(i.v("name")))
    },
    SDKOperation(id: "al.appLookup", category: "Aliases", name: "lookupApplicationAlias",
                 summary: "Resolve application alias", fields: [.line("name", "Alias name")]) { m, i in
        Fmt.json(try await m.admin.lookupApplicationAlias(i.v("name")))
    },
    SDKOperation(id: "al.ctxDelete", category: "Aliases", name: "deleteContextAlias",
                 summary: "Delete context alias", fields: [.line("name", "Alias name")]) { m, i in
        Fmt.json(try await m.admin.deleteContextAlias(i.v("name")))
    },
    SDKOperation(id: "al.appDelete", category: "Aliases", name: "deleteApplicationAlias",
                 summary: "Delete application alias", fields: [.line("name", "Alias name")]) { m, i in
        Fmt.json(try await m.admin.deleteApplicationAlias(i.v("name")))
    },
    SDKOperation(id: "al.ctxList", category: "Aliases", name: "listContextAliases",
                 summary: "All context aliases", fields: []) { m, _ in Fmt.json(try await m.admin.listContextAliases()) },
    SDKOperation(id: "al.appList", category: "Aliases", name: "listApplicationAliases",
                 summary: "All application aliases", fields: []) { m, _ in Fmt.json(try await m.admin.listApplicationAliases()) },
    SDKOperation(id: "al.idList", category: "Aliases", name: "listContextIdentityAliases",
                 summary: "Identity aliases in a context", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.listContextIdentityAliases(i.v("contextId")))
    },
    SDKOperation(id: "al.idCreate", category: "Aliases", name: "createContextIdentityAlias",
                 summary: "Create identity alias", fields: [.line("contextId", "Context ID"), .json("body", "Request")]) { m, i in
        Fmt.json(try await m.admin.createContextIdentityAlias(i.v("contextId"), request: try Fmt.decode(i.v("body"), CreateContextIdentityAliasRequest.self)))
    },
    SDKOperation(id: "al.idLookup", category: "Aliases", name: "lookupContextIdentityAlias",
                 summary: "Resolve identity alias", fields: [.line("contextId", "Context ID"), .line("name", "Alias name")]) { m, i in
        Fmt.json(try await m.admin.lookupContextIdentityAlias(i.v("contextId"), name: i.v("name")))
    },
    SDKOperation(id: "al.idDelete", category: "Aliases", name: "deleteContextIdentityAlias",
                 summary: "Delete identity alias", fields: [.line("contextId", "Context ID"), .line("name", "Alias name")]) { m, i in
        Fmt.json(try await m.admin.deleteContextIdentityAlias(i.v("contextId"), name: i.v("name")))
    },
]

// MARK: Blobs

private let blobOps: [SDKOperation] = [
    SDKOperation(id: "blob.list", category: "Blobs", name: "listBlobs",
                 summary: "All blobs", fields: []) { m, _ in Fmt.json(try await m.admin.listBlobs()) },
    SDKOperation(id: "blob.upload", category: "Blobs", name: "uploadBlob",
                 summary: "Upload text as a blob", fields: [.line("text", "Text to upload"), .line("contextId", "Context ID (optional)")]) { m, i in
        let req = UploadBlobRequest(data: Data(i.v("text").utf8), hash: nil, contextId: i.opt("contextId"))
        return Fmt.json(try await m.admin.uploadBlob(req))
    },
    SDKOperation(id: "blob.info", category: "Blobs", name: "getBlobInfo",
                 summary: "Blob metadata (HEAD)", fields: [.line("blobId", "Blob ID")]) { m, i in
        Fmt.json(try await m.admin.getBlobInfo(i.v("blobId")))
    },
    SDKOperation(id: "blob.get", category: "Blobs", name: "getBlob",
                 summary: "Download blob bytes", fields: [.line("blobId", "Blob ID")]) { m, i in
        let data = try await m.admin.getBlob(i.v("blobId"))
        let preview = String(data: data.prefix(400), encoding: .utf8) ?? data.prefix(64).map { String(format: "%02x", $0) }.joined()
        return "\(data.count) bytes\n\n\(preview)"
    },
    SDKOperation(id: "blob.delete", category: "Blobs", name: "deleteBlob",
                 summary: "Delete a blob", fields: [.line("blobId", "Blob ID")]) { m, i in
        Fmt.json(try await m.admin.deleteBlob(i.v("blobId")))
    },
]

// MARK: Namespaces

private let nsOps: [SDKOperation] = [
    SDKOperation(id: "ns.list", category: "Namespaces", name: "listNamespaces",
                 summary: "All namespaces", fields: []) { m, _ in Fmt.json(try await m.admin.listNamespaces()) },
    SDKOperation(id: "ns.get", category: "Namespaces", name: "getNamespace",
                 summary: "One namespace", fields: [.line("namespaceId", "Namespace ID")]) { m, i in
        Fmt.json(try await m.admin.getNamespace(i.v("namespaceId")))
    },
    SDKOperation(id: "ns.identity", category: "Namespaces", name: "getNamespaceIdentity",
                 summary: "Namespace identity", fields: [.line("namespaceId", "Namespace ID")]) { m, i in
        Fmt.json(try await m.admin.getNamespaceIdentity(i.v("namespaceId")))
    },
    SDKOperation(id: "ns.create", category: "Namespaces", name: "createNamespace",
                 summary: "Create a namespace", fields: [.json("body", "CreateNamespaceRequest")]) { m, i in
        Fmt.json(try await m.admin.createNamespace(try Fmt.decode(i.v("body"), CreateNamespaceRequest.self)))
    },
    SDKOperation(id: "ns.delete", category: "Namespaces", name: "deleteNamespace",
                 summary: "Delete a namespace", fields: [.line("namespaceId", "Namespace ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: DeleteNamespaceRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), DeleteNamespaceRequest.self) : nil
        return Fmt.json(try await m.admin.deleteNamespace(i.v("namespaceId"), request: req))
    },
    SDKOperation(id: "ns.invite", category: "Namespaces", name: "createNamespaceInvitation",
                 summary: "Invite to a namespace", fields: [.line("namespaceId", "Namespace ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: CreateNamespaceInvitationRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), CreateNamespaceInvitationRequest.self) : nil
        return Fmt.json(try await m.admin.createNamespaceInvitation(i.v("namespaceId"), request: req))
    },
    SDKOperation(id: "ns.join", category: "Namespaces", name: "joinNamespace",
                 summary: "Join a namespace", fields: [.line("namespaceId", "Namespace ID"), .json("body", "JoinNamespaceRequest")]) { m, i in
        Fmt.json(try await m.admin.joinNamespace(i.v("namespaceId"), request: try Fmt.decode(i.v("body"), JoinNamespaceRequest.self)))
    },
    SDKOperation(id: "ns.leave", category: "Namespaces", name: "leaveNamespace",
                 summary: "Leave a namespace", fields: [.line("namespaceId", "Namespace ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: [String: JSONValue]? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), [String: JSONValue].self) : nil
        try await m.admin.leaveNamespace(i.v("namespaceId"), request: req)
        return "✓ left namespace"
    },
    SDKOperation(id: "ns.groupCreate", category: "Namespaces", name: "createGroupInNamespace",
                 summary: "Create a group in a namespace", fields: [.line("namespaceId", "Namespace ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: CreateGroupInNamespaceRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), CreateGroupInNamespaceRequest.self) : nil
        return Fmt.json(try await m.admin.createGroupInNamespace(i.v("namespaceId"), request: req))
    },
    SDKOperation(id: "ns.groups", category: "Namespaces", name: "listNamespaceGroups",
                 summary: "Groups in a namespace", fields: [.line("namespaceId", "Namespace ID")]) { m, i in
        Fmt.json(try await m.admin.listNamespaceGroups(i.v("namespaceId")))
    },
    SDKOperation(id: "ns.migStatus", category: "Namespaces", name: "getMigrationStatus",
                 summary: "Migration rollup", fields: [.line("namespaceId", "Namespace ID")]) { m, i in
        Fmt.json(try await m.admin.getMigrationStatus(i.v("namespaceId")))
    },
    SDKOperation(id: "ns.cascade", category: "Namespaces", name: "getCascadeStatus",
                 summary: "Per-group cascade status", fields: [.line("namespaceId", "Namespace ID")]) { m, i in
        Fmt.json(try await m.admin.getCascadeStatus(i.v("namespaceId")))
    },
    SDKOperation(id: "ns.abort", category: "Namespaces", name: "abortMigration",
                 summary: "Abort a migration", fields: [.line("namespaceId", "Namespace ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: [String: JSONValue]? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), [String: JSONValue].self) : nil
        return Fmt.json(try await m.admin.abortMigration(i.v("namespaceId"), request: req))
    },
    SDKOperation(id: "ns.nsProof", category: "Namespaces", name: "issueNamespaceOwnershipProof",
                 summary: "Namespace ownership proof", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: [String: JSONValue]? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), [String: JSONValue].self) : nil
        return Fmt.json(try await m.admin.issueNamespaceOwnershipProof(i.v("groupId"), request: req))
    },
]

// MARK: Groups

private let groupOps: [SDKOperation] = [
    SDKOperation(id: "grp.create", category: "Groups", name: "createGroup",
                 summary: "Create a standalone group", fields: [.json("body", "Body ([String:JSONValue])")]) { m, i in
        Fmt.json(try await m.admin.createGroup(try Fmt.decode(i.v("body"), [String: JSONValue].self)))
    },
    SDKOperation(id: "grp.info", category: "Groups", name: "getGroupInfo",
                 summary: "Group info", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.getGroupInfo(i.v("groupId")))
    },
    SDKOperation(id: "grp.delete", category: "Groups", name: "deleteGroup",
                 summary: "Delete a group", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: DeleteGroupRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), DeleteGroupRequest.self) : nil
        return Fmt.json(try await m.admin.deleteGroup(i.v("groupId"), request: req))
    },
    SDKOperation(id: "grp.contexts", category: "Groups", name: "listGroupContexts",
                 summary: "Contexts in a group", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.listGroupContexts(i.v("groupId")))
    },
    SDKOperation(id: "grp.subgroups", category: "Groups", name: "listSubgroups",
                 summary: "Child subgroups", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.listSubgroups(i.v("groupId")))
    },
    SDKOperation(id: "grp.leave", category: "Groups", name: "leaveGroup",
                 summary: "Leave a group", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: [String: JSONValue]? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), [String: JSONValue].self) : nil
        try await m.admin.leaveGroup(i.v("groupId"), request: req)
        return "✓ left group"
    },
    SDKOperation(id: "grp.defCaps", category: "Groups", name: "getDefaultCapabilities",
                 summary: "Default capabilities bitmask", fields: [.line("groupId", "Group ID")]) { m, i in
        "defaultCapabilities = \(try await m.admin.getDefaultCapabilities(i.v("groupId")))"
    },
    SDKOperation(id: "grp.subVis", category: "Groups", name: "getSubgroupVisibility",
                 summary: "Subgroup visibility", fields: [.line("groupId", "Group ID")]) { m, i in
        "subgroupVisibility = \(try await m.admin.getSubgroupVisibility(i.v("groupId")))"
    },
    SDKOperation(id: "grp.detach", category: "Groups", name: "detachContextFromGroup",
                 summary: "Detach a context", fields: [.line("groupId", "Group ID"), .line("contextId", "Context ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: DetachContextFromGroupRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), DetachContextFromGroupRequest.self) : nil
        try await m.admin.detachContextFromGroup(i.v("groupId"), contextId: i.v("contextId"), request: req)
        return "✓ detached"
    },
    SDKOperation(id: "grp.reparent", category: "Groups", name: "reparentGroup",
                 summary: "Move under a new parent", fields: [.line("childGroupId", "Child group ID"), .json("body", "ReparentGroupRequest")]) { m, i in
        Fmt.json(try await m.admin.reparentGroup(i.v("childGroupId"), request: try Fmt.decode(i.v("body"), ReparentGroupRequest.self)))
    },
    SDKOperation(id: "grp.proof", category: "Groups", name: "issueOwnershipProof",
                 summary: "Group ownership proof", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: [String: JSONValue]? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), [String: JSONValue].self) : nil
        return Fmt.json(try await m.admin.issueOwnershipProof(i.v("groupId"), request: req))
    },
    SDKOperation(id: "grp.sync", category: "Groups", name: "syncGroup",
                 summary: "Sync a group", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: SyncGroupRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), SyncGroupRequest.self) : nil
        return Fmt.json(try await m.admin.syncGroup(i.v("groupId"), request: req))
    },
    SDKOperation(id: "grp.signKey", category: "Groups", name: "registerGroupSigningKey",
                 summary: "Register a signing key", fields: [.line("groupId", "Group ID"), .json("body", "Request")]) { m, i in
        Fmt.json(try await m.admin.registerGroupSigningKey(i.v("groupId"), request: try Fmt.decode(i.v("body"), RegisterGroupSigningKeyRequest.self)))
    },
]

// MARK: Group Members

private let memberOps: [SDKOperation] = [
    SDKOperation(id: "mem.list", category: "Group Members", name: "listGroupMembers",
                 summary: "Members of a group", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.listGroupMembers(i.v("groupId")))
    },
    SDKOperation(id: "mem.add", category: "Group Members", name: "addGroupMembers",
                 summary: "Add members", fields: [.line("groupId", "Group ID"), .json("body", "AddGroupMembersRequest")]) { m, i in
        try await m.admin.addGroupMembers(i.v("groupId"), request: try Fmt.decode(i.v("body"), AddGroupMembersRequest.self))
        return "✓ members added"
    },
    SDKOperation(id: "mem.remove", category: "Group Members", name: "removeGroupMembers",
                 summary: "Remove members", fields: [.line("groupId", "Group ID"), .json("body", "RemoveGroupMembersRequest")]) { m, i in
        try await m.admin.removeGroupMembers(i.v("groupId"), request: try Fmt.decode(i.v("body"), RemoveGroupMembersRequest.self))
        return "✓ members removed"
    },
    SDKOperation(id: "mem.role", category: "Group Members", name: "updateMemberRole",
                 summary: "Change a member's role", fields: [.line("groupId", "Group ID"), .line("identity", "Identity"), .json("body", "UpdateMemberRoleRequest")]) { m, i in
        try await m.admin.updateMemberRole(i.v("groupId"), identity: i.v("identity"), request: try Fmt.decode(i.v("body"), UpdateMemberRoleRequest.self))
        return "✓ role updated"
    },
    SDKOperation(id: "mem.getCaps", category: "Group Members", name: "getMemberCapabilities",
                 summary: "Member capabilities", fields: [.line("groupId", "Group ID"), .line("identity", "Identity")]) { m, i in
        Fmt.json(try await m.admin.getMemberCapabilities(i.v("groupId"), identity: i.v("identity")))
    },
    SDKOperation(id: "mem.setCaps", category: "Group Members", name: "setMemberCapabilities",
                 summary: "Set member capabilities", fields: [.line("groupId", "Group ID"), .line("identity", "Identity"), .json("body", "Request")]) { m, i in
        try await m.admin.setMemberCapabilities(i.v("groupId"), identity: i.v("identity"), request: try Fmt.decode(i.v("body"), SetMemberCapabilitiesRequest.self))
        return "✓ capabilities set"
    },
    SDKOperation(id: "mem.autoFollow", category: "Group Members", name: "setMemberAutoFollow",
                 summary: "Set auto-follow", fields: [.line("groupId", "Group ID"), .line("identity", "Identity"), .json("body", "Body", "{\"autoFollow\":true}")]) { m, i in
        try await m.admin.setMemberAutoFollow(i.v("groupId"), identity: i.v("identity"), request: try Fmt.decode(i.v("body"), [String: JSONValue].self))
        return "✓ auto-follow set"
    },
    SDKOperation(id: "mem.getMeta", category: "Group Members", name: "getMemberMetadata",
                 summary: "Member metadata", fields: [.line("groupId", "Group ID"), .line("identity", "Identity")]) { m, i in
        Fmt.json(try await m.admin.getMemberMetadata(i.v("groupId"), identity: i.v("identity")))
    },
    SDKOperation(id: "mem.setMeta", category: "Group Members", name: "setMemberMetadata",
                 summary: "Set member metadata", fields: [.line("groupId", "Group ID"), .line("identity", "Identity"), .json("body", "Request")]) { m, i in
        try await m.admin.setMemberMetadata(i.v("groupId"), identity: i.v("identity"), request: try Fmt.decode(i.v("body"), SetMemberMetadataRequest.self))
        return "✓ metadata set"
    },
]

// MARK: Group Settings & Metadata

private let settingsOps: [SDKOperation] = [
    SDKOperation(id: "set.defCaps", category: "Group Settings", name: "setDefaultCapabilities",
                 summary: "Set default capabilities", fields: [.line("groupId", "Group ID"), .json("body", "Request")]) { m, i in
        try await m.admin.setDefaultCapabilities(i.v("groupId"), request: try Fmt.decode(i.v("body"), SetDefaultCapabilitiesRequest.self))
        return "✓ set"
    },
    SDKOperation(id: "set.subVis", category: "Group Settings", name: "setSubgroupVisibility",
                 summary: "Set subgroup visibility", fields: [.line("groupId", "Group ID"), .json("body", "Request")]) { m, i in
        try await m.admin.setSubgroupVisibility(i.v("groupId"), request: try Fmt.decode(i.v("body"), SetSubgroupVisibilityRequest.self))
        return "✓ set"
    },
    SDKOperation(id: "set.update", category: "Group Settings", name: "updateGroupSettings",
                 summary: "Patch group settings", fields: [.line("groupId", "Group ID"), .json("body", "Request")]) { m, i in
        try await m.admin.updateGroupSettings(i.v("groupId"), request: try Fmt.decode(i.v("body"), UpdateGroupSettingsRequest.self))
        return "✓ updated"
    },
    SDKOperation(id: "set.grpMetaSet", category: "Group Settings", name: "setGroupMetadata",
                 summary: "Set group metadata", fields: [.line("groupId", "Group ID"), .json("body", "Request")]) { m, i in
        try await m.admin.setGroupMetadata(i.v("groupId"), request: try Fmt.decode(i.v("body"), SetGroupMetadataRequest.self))
        return "✓ set"
    },
    SDKOperation(id: "set.grpMetaGet", category: "Group Settings", name: "getGroupMetadata",
                 summary: "Get group metadata", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.getGroupMetadata(i.v("groupId")))
    },
    SDKOperation(id: "set.ctxMetaSet", category: "Group Settings", name: "setContextMetadata",
                 summary: "Set context metadata", fields: [.line("groupId", "Group ID"), .line("contextId", "Context ID"), .json("body", "Request")]) { m, i in
        try await m.admin.setContextMetadata(i.v("groupId"), contextId: i.v("contextId"), request: try Fmt.decode(i.v("body"), SetContextMetadataRequest.self))
        return "✓ set"
    },
    SDKOperation(id: "set.ctxMetaGet", category: "Group Settings", name: "getContextMetadata",
                 summary: "Get context metadata", fields: [.line("groupId", "Group ID"), .line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.admin.getContextMetadata(i.v("groupId"), contextId: i.v("contextId")))
    },
    SDKOperation(id: "set.teeGet", category: "Group Settings", name: "getTeeAdmissionPolicy",
                 summary: "Get TEE admission policy", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.getTeeAdmissionPolicy(i.v("groupId")))
    },
    SDKOperation(id: "set.teeSet", category: "Group Settings", name: "setTeeAdmissionPolicy",
                 summary: "Set TEE admission policy", fields: [.line("groupId", "Group ID"), .json("body", "Request")]) { m, i in
        try await m.admin.setTeeAdmissionPolicy(i.v("groupId"), request: try Fmt.decode(i.v("body"), SetTeeAdmissionPolicyRequest.self))
        return "✓ set"
    },
]

// MARK: Group Upgrade / Migration & Invitations

private let upgradeOps: [SDKOperation] = [
    SDKOperation(id: "up.upgrade", category: "Upgrade & Invites", name: "upgradeGroup",
                 summary: "Upgrade a group's app", fields: [.line("groupId", "Group ID"), .json("body", "UpgradeGroupRequest")]) { m, i in
        Fmt.json(try await m.admin.upgradeGroup(i.v("groupId"), request: try Fmt.decode(i.v("body"), UpgradeGroupRequest.self)))
    },
    SDKOperation(id: "up.status", category: "Upgrade & Invites", name: "getGroupUpgradeStatus",
                 summary: "Upgrade status (nullable)", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.getGroupUpgradeStatus(i.v("groupId")))
    },
    SDKOperation(id: "up.retry", category: "Upgrade & Invites", name: "retryGroupUpgrade",
                 summary: "Retry an upgrade", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: RetryGroupUpgradeRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), RetryGroupUpgradeRequest.self) : nil
        return Fmt.json(try await m.admin.retryGroupUpgrade(i.v("groupId"), request: req))
    },
    SDKOperation(id: "up.invite", category: "Upgrade & Invites", name: "createGroupInvitation",
                 summary: "Invite to a group", fields: [.line("groupId", "Group ID"), .json("body", "Body (optional)", "")]) { m, i in
        let req: CreateGroupInvitationRequest? = i.opt("body") != nil ? try Fmt.decode(i.v("body"), CreateGroupInvitationRequest.self) : nil
        return Fmt.json(try await m.admin.createGroupInvitation(i.v("groupId"), request: req))
    },
    SDKOperation(id: "up.join", category: "Upgrade & Invites", name: "joinGroup",
                 summary: "Join a group via invitation", fields: [.json("body", "JoinGroupRequest")]) { m, i in
        Fmt.json(try await m.admin.joinGroup(try Fmt.decode(i.v("body"), JoinGroupRequest.self)))
    },
    SDKOperation(id: "up.joinInherit", category: "Upgrade & Invites", name: "joinSubgroupInheritance",
                 summary: "Join a subgroup via inheritance", fields: [.line("groupId", "Group ID")]) { m, i in
        Fmt.json(try await m.admin.joinSubgroupInheritance(i.v("groupId")))
    },
]

// MARK: TEE

private let teeOps: [SDKOperation] = [
    SDKOperation(id: "tee.info", category: "TEE", name: "getTeeInfo",
                 summary: "TEE info", fields: []) { m, _ in Fmt.json(try await m.admin.getTeeInfo()) },
    SDKOperation(id: "tee.attest", category: "TEE", name: "teeAttest",
                 summary: "Request an attestation quote", fields: [.json("body", "TeeAttestRequest")]) { m, i in
        Fmt.json(try await m.admin.teeAttest(try Fmt.decode(i.v("body"), TeeAttestRequest.self)))
    },
    SDKOperation(id: "tee.verify", category: "TEE", name: "teeVerifyQuote",
                 summary: "Verify an attestation quote", fields: [.json("body", "TeeVerifyQuoteRequest")]) { m, i in
        Fmt.json(try await m.admin.teeVerifyQuote(try Fmt.decode(i.v("body"), TeeVerifyQuoteRequest.self)))
    },
]

// MARK: RPC

private let rpcOps: [SDKOperation] = [
    SDKOperation(id: "rpc.execute", category: "RPC", name: "rpc.execute",
                 summary: "Call a contract method", fields: [.line("contextId", "Context ID"), .line("method", "Method"), .json("args", "argsJson", "{}")]) { m, i in
        let args: [String: JSONValue] = i.opt("args") != nil ? try Fmt.decode(i.v("args"), [String: JSONValue].self) : [:]
        let out: JSONValue = try await m.rpc.execute(contextId: i.v("contextId"), method: i.v("method"), argsJson: args)
        return Fmt.json(out)
    },
    SDKOperation(id: "rpc.migrate", category: "RPC", name: "rpc.migrateMyEntries",
                 summary: "Re-sign my entries to current schema", fields: [.line("contextId", "Context ID")]) { m, i in
        Fmt.json(try await m.rpc.migrateMyEntries(i.v("contextId")))
    },
    SDKOperation(id: "rpc.pending", category: "RPC", name: "rpc.countMyPending",
                 summary: "Count my pending entries", fields: [.line("contextId", "Context ID")]) { m, i in
        "pending = \(try await m.rpc.countMyPending(i.v("contextId")))"
    },
]

/// The full registry, in display order.
let sdkOperations: [SDKOperation] =
    healthOps + authOps + keyOps + appOps + pkgOps + ctxOps + ctxIdOps
    + aliasOps + blobOps + nsOps + groupOps + memberOps + settingsOps + upgradeOps + teeOps + rpcOps

/// Categories in display order (as first seen in `sdkOperations`).
let sdkCategories: [String] = {
    var seen: Set<String> = []
    var order: [String] = []
    for op in sdkOperations where !seen.contains(op.category) {
        seen.insert(op.category)
        order.append(op.category)
    }
    return order
}()
