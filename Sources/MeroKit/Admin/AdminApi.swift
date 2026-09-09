// Admin API client — ported 1:1 from mero-js `src/admin-api/admin-client.ts`.
//
// Every method mirrors the TypeScript `AdminApiClient`: same HTTP verb, path,
// query params, request-body shape, and response unwrapping. Most reads unwrap
// core's `{ data: T }` envelope and throw `MeroError.emptyResponse` when the
// inner payload is missing; the handful of endpoints core serializes flat
// (or that legitimately return `null`) are handled explicitly and documented at
// each site, matching the TS.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Query / path percent-encoding helpers

extension CharacterSet {
    /// Strict RFC-3986 unreserved set — used for both query-parameter values and
    /// path segments (the TS uses `URLSearchParams` for the former and
    /// `encodeURIComponent` for the latter; this covers both safely).
    static let urlQueryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

extension String {
    /// Percent-encode for use as a query value or a path segment.
    func percentEncoded() -> String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

/// Compare two dotted version strings, ascending: negative if `a < b`, positive
/// if `a > b`, `0` if equal. Components are compared numerically when both parse
/// as integers (so `1.10.0 > 1.9.0`), else lexically; a missing component is `0`.
/// Minimal by design — sufficient for the `major.minor.patch` registry versions.
public func compareSemver(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let pb = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let n = max(pa.count, pb.count)
    for i in 0..<n {
        let sa = i < pa.count ? pa[i] : "0"
        let sb = i < pb.count ? pb[i] : "0"
        if let na = Int(sa), let nb = Int(sb) {
            if na != nb { return na - nb }
        } else {
            let c = sa.compare(sb)
            if c != .orderedSame { return c == .orderedAscending ? -1 : 1 }
        }
    }
    return 0
}

// MARK: - Internal wire structs (blob DTOs use snake_case `blob_id`)

private struct BlobWire: Codable, Sendable {
    let blobId: String
    let size: Int
    enum CodingKeys: String, CodingKey {
        case blobId = "blob_id"
        case size
    }
}

private struct BlobsWire: Codable, Sendable {
    let blobs: [BlobWire]
}

private struct DeleteBlobWire: Codable, Sendable {
    let blobId: String
    let deleted: Bool
    enum CodingKeys: String, CodingKey {
        case blobId = "blob_id"
        case deleted
    }
}

/// Encodes to an empty JSON object `{}` — matches the many TS calls that POST `{}`.
private struct EmptyObject: Encodable {}

// MARK: - AdminApi

public struct AdminApi: Sendable {
    let http: any HttpClient

    public init(http: any HttpClient) {
        self.http = http
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Helpers

    private func unwrap<T>(_ resp: ApiResponse<T>, _ context: String) throws -> T {
        guard let data = resp.data else { throw MeroError.emptyResponse(context) }
        return data
    }

    /// For routes whose success body carries no payload.
    ///
    /// ⚠️ Needed because core answers the alias mutations `{"data": null}`, and
    /// `unwrap` reads a null `data` as a failure — so these calls used to throw
    /// on success. A transport-level failure has already thrown by the time this
    /// runs; an `error` string alongside a null `data` is the only thing left to
    /// catch here.
    private func emptyOK(_ resp: ApiResponse<Empty>, _ context: String) throws -> Empty {
        if let error = resp.error, !error.isEmpty {
            throw MeroError.emptyResponse("\(context): \(error)")
        }
        return resp.data ?? Empty()
    }

    private func jsonRequest(
        _ path: String, method: HTTPMethod, body: some Encodable, timeout: TimeInterval? = nil
    ) throws -> HttpRequest {
        let data = try Self.encoder.encode(body)
        return HttpRequest(path: path, method: method, body: .json(data), headers: [:], timeout: timeout)
    }

    /// For endpoints typed `unknown` in the TS: decode the raw body into a
    /// dynamic `JSONValue`, tolerating an empty 2xx body (→ `.null`).
    private func rawJSON(_ req: HttpRequest) async throws -> JSONValue {
        let (data, _) = try await http.sendRaw(req)
        guard !data.isEmpty else { return .null }
        return (try? Self.decoder.decode(JSONValue.self, from: data)) ?? .null
    }

    /// Resolve the origin (scheme://host[:port]) of a registry URL.
    private func origin(of urlString: String) throws -> String {
        guard let comps = URLComponents(string: urlString), let scheme = comps.scheme, let host = comps.host else {
            throw MeroError.emptyResponse("invalid registry URL: \(urlString)")
        }
        if let port = comps.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Plain external GET (registry endpoints live off-node, not behind HttpClient).
    private func fetchJSON<T: Decodable>(_ url: URL, failure: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MeroError.emptyResponse("\(failure) (\(http.statusCode))")
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: - Health and Status (public, no auth)

    public func healthCheck() async throws -> HealthStatus {
        let resp: ApiResponse<HealthStatus> = try await http.get("/admin-api/health")
        return try unwrap(resp, "healthCheck")
    }

    /// Whether the node is ready to serve, as distinct from merely alive.
    /// `healthCheck` answers as soon as the process is listening.
    public func readinessCheck() async throws -> HealthStatus {
        let resp: ApiResponse<HealthStatus> = try await http.get("/admin-api/ready")
        return try unwrap(resp, "readinessCheck")
    }

    public func isAuthed() async throws -> AdminAuthStatus {
        return try await http.get("/admin-api/is-authed")
    }

    // MARK: - Application Management

    /// Install a published application by coordinates.
    ///
    /// The node fetches it from the one source its own `[registry]` section
    /// names — see ``InstallApplicationRequest`` for why there is no URL any
    /// more, and what an rc.32 node answers when the coordinates are not
    /// published there.
    public func installApplication(_ request: InstallApplicationRequest) async throws -> InstallApplicationResponseData
    {
        let resp: ApiResponse<InstallApplicationResponseData> = try await http.post(
            "/admin-api/install-application", json: request)
        return try unwrap(resp, "installApplication")
    }

    /// Install `package@version` from the node's configured registry.
    ///
    /// The discrete "download" step an Updates flow pairs with a subsequent
    /// `upgradeGroup`. One request now: the node resolves the version, fetches
    /// the `.mpk` and checks its blob id against the coordinates itself.
    ///
    /// ⚠️ Where it comes from is the **node's** `[registry]`, not a URL this
    /// call chooses. Before core 0.11.0-rc.31 this method fetched the registry's
    /// bundle manifest, derived an artifact URL and posted that; rc.31 refuses a
    /// body carrying a URL outright (core#3652), so the `registryUrl` argument
    /// is gone with nothing to replace it — a node pointed at the wrong registry
    /// is fixed in the node's config, not per call.
    public func installFromRegistry(
        packageName: String,
        version: String
    ) async throws -> InstallApplicationResponseData {
        return try await installApplication(
            InstallApplicationRequest(package: packageName, version: version))
    }

    /// List a package's published versions from the registry, newest-first by
    /// semver. Reads the registry's V2 bundle listing
    /// (`GET {registry}/api/v2/bundles?package={package}`), taking each bundle's
    /// `appVersion`. Registry-side data — distinct from the node's
    /// installed-version list — and the source an Updates view compares against
    /// the running `Context.applicationVersion` to detect "a new version exists".
    public func getRegistryVersions(registryUrl: String, packageName: String) async throws -> [String] {
        let base = try origin(of: registryUrl)
        guard let url = URL(string: "\(base)/api/v2/bundles?package=\(packageName.percentEncoded())") else {
            throw MeroError.emptyResponse("invalid registry versions URL for \(packageName)")
        }
        let bundles: [RegistryBundleManifest] = try await fetchJSON(
            url,
            failure: "registry versions fetch failed for \(packageName)"
        )
        return bundles.map { $0.appVersion }.sorted { compareSemver($0, $1) > 0 }
    }

    public func installDevApplication(
        _ request: InstallDevApplicationRequest
    ) async throws -> InstallApplicationResponseData {
        let resp: ApiResponse<InstallApplicationResponseData> = try await http.post(
            "/admin-api/install-dev-application", json: request)
        return try unwrap(resp, "installDevApplication")
    }

    public func uninstallApplication(_ appId: String) async throws -> UninstallApplicationResponseData {
        let resp: ApiResponse<UninstallApplicationResponseData> = try await http.delete(
            "/admin-api/applications/\(appId)")
        return try unwrap(resp, "uninstallApplication")
    }

    public func listApplications() async throws -> ListApplicationsResponseData {
        let resp: ApiResponse<ListApplicationsResponseData> = try await http.get("/admin-api/applications")
        return try unwrap(resp, "listApplications")
    }

    public func getApplication(_ appId: String) async throws -> GetApplicationResponseData {
        let resp: ApiResponse<GetApplicationResponseData> = try await http.get("/admin-api/applications/\(appId)")
        return try unwrap(resp, "getApplication")
    }

    /// Installed-blob inventory for an application — one entry per locally installed
    /// version. This is the *installed* inventory (source for a "pick a version to
    /// pin" UI); the registry equivalent is `listPackageVersions`.
    public func listApplicationVersions(_ applicationId: String) async throws -> [ApplicationVersionEntry] {
        let resp: ApiResponse<[ApplicationVersionEntry]> = try await http.get(
            "/admin-api/applications/\(applicationId)/versions")
        return try unwrap(resp, "listApplicationVersions")
    }

    /// The application's ABI as `cargo mero build` emitted it.
    ///
    /// `serviceName` selects one service out of a multi-service bundle; omit it
    /// for a single-wasm app.
    public func getApplicationAbi(
        _ applicationId: String, serviceName: String? = nil
    ) async throws -> ApplicationAbi {
        var path = "/admin-api/applications/\(applicationId)/abi"
        if let serviceName {
            path += "?service_name=\(serviceName.percentEncoded())"
        }
        let resp: ApiResponse<ApplicationAbi> = try await http.get(path)
        return try unwrap(resp, "getApplicationAbi")
    }

    // MARK: - Package Management

    public func listPackages() async throws -> ListPackagesResponseData {
        // Core returns this flat ({ packages: [...] }), not under `data`; tolerate both.
        struct Wire: Codable, Sendable { let packages: [String]?; let data: ListPackagesResponseData? }
        let wire: Wire = try await http.get("/admin-api/packages")
        if let d = wire.data { return d }
        return ListPackagesResponseData(packages: wire.packages ?? [])
    }

    public func listPackageVersions(_ packageName: String) async throws -> ListVersionsResponseData {
        // Core returns this flat ({ versions: [...] }), not under `data`; tolerate both.
        struct Wire: Codable, Sendable { let versions: [String]?; let data: ListVersionsResponseData? }
        let wire: Wire = try await http.get("/admin-api/packages/\(packageName.percentEncoded())/versions")
        if let d = wire.data { return d }
        return ListVersionsResponseData(versions: wire.versions ?? [])
    }

    public func getLatestPackageVersion(_ packageName: String) async throws -> GetLatestVersionResponseData {
        return try await http.get("/admin-api/packages/\(packageName.percentEncoded())/latest")
    }

    // MARK: - Context Management

    public func createContext(_ request: CreateContextRequest) async throws -> CreateContextResponseData {
        // Core requires `initializationParams` (no default); default it to an empty
        // byte array so callers that pass none don't get a 400.
        var body = request
        if body.initializationParams == nil { body.initializationParams = [] }
        let resp: ApiResponse<CreateContextResponseData> = try await http.post("/admin-api/contexts", json: body)
        return try unwrap(resp, "createContext")
    }

    public func deleteContext(
        _ contextId: String, request: DeleteContextRequest? = nil
    ) async throws -> DeleteContextResponseData {
        let resp: ApiResponse<DeleteContextResponseData>
        if let request {
            resp = try await http.delete("/admin-api/contexts/\(contextId)", json: request)
        } else {
            resp = try await http.delete("/admin-api/contexts/\(contextId)")
        }
        return try unwrap(resp, "deleteContext")
    }

    public func getContexts() async throws -> GetContextsResponseData {
        let resp: ApiResponse<GetContextsResponseData> = try await http.get("/admin-api/contexts")
        return try unwrap(resp, "getContexts")
    }

    public func getContext(_ contextId: String) async throws -> Context {
        let resp: ApiResponse<Context> = try await http.get("/admin-api/contexts/\(contextId)")
        return try unwrap(resp, "getContext")
    }

    public func getContextsForApplication(_ applicationId: String) async throws -> GetContextsResponseData {
        let resp: ApiResponse<GetContextsResponseData> = try await http.get(
            "/admin-api/contexts/for-application/\(applicationId)")
        return try unwrap(resp, "getContextsForApplication")
    }

    // MARK: - Context Identity

    /// Who this node is: its account, its device, and its keys.
    ///
    /// The replacement for the per-namespace identity route core deleted in
    /// 0.11.0-rc.23 (core#3522). Since rc.27 an account id and a device key are
    /// both 64 hex characters, so this response is the only thing that maps one
    /// to the other — and handing a device key where an account belongs (a role
    /// grant, an `admitters` entry) succeeds and authorizes nobody.
    public func getNodeIdentity() async throws -> NodeIdentity {
        let resp: ApiResponse<NodeIdentity> = try await http.get("/admin-api/identity")
        return try unwrap(resp, "getNodeIdentity")
    }

    public func generateContextIdentity() async throws -> GenerateContextIdentityResponseData {
        let resp: ApiResponse<GenerateContextIdentityResponseData> = try await http.post(
            "/admin-api/identity/context", json: EmptyObject())
        return try unwrap(resp, "generateContextIdentity")
    }

    public func getContextIdentities(_ contextId: String) async throws -> GetContextIdentitiesResponseData {
        let resp: ApiResponse<GetContextIdentitiesResponseData> = try await http.get(
            "/admin-api/contexts/\(contextId)/identities")
        return try unwrap(resp, "getContextIdentities")
    }

    public func getContextIdentitiesOwned(_ contextId: String) async throws -> GetContextIdentitiesResponseData {
        let resp: ApiResponse<GetContextIdentitiesResponseData> = try await http.get(
            "/admin-api/contexts/\(contextId)/identities-owned")
        return try unwrap(resp, "getContextIdentitiesOwned")
    }

    // MARK: - Context join (group membership)

    public func joinContext(_ contextId: String) async throws -> JoinContextResponseData {
        let resp: ApiResponse<JoinContextResponseData> = try await http.post(
            "/admin-api/contexts/\(contextId)/join", json: EmptyObject())
        return try unwrap(resp, "joinContext")
    }

    // MARK: - Context group / storage / sync

    public func getContextGroup(_ contextId: String) async throws -> ContextGroupResponseData {
        // Value is `string | null`; return the optional directly (do NOT throw on null).
        let resp: ApiResponse<String> = try await http.get("/admin-api/contexts/\(contextId)/group")
        return resp.data
    }

    public func getContextStorage(_ contextId: String) async throws -> ContextStorageResponseData {
        let resp: ApiResponse<ContextStorageResponseData> = try await http.get(
            "/admin-api/contexts/\(contextId)/storage")
        return try unwrap(resp, "getContextStorage")
    }

    /// Sync one context, or every context when `contextId` is nil.
    ///
    /// ⚠️ The sync-everything form must not carry a trailing slash. core moved to
    /// axum 0.8 in 0.11.0-rc.30, which stopped matching `/contexts/sync/` against
    /// the `/contexts/sync` route — so the interpolated-empty-id path this used to
    /// build now answers 404, and nothing gets synced.
    public func syncContext(_ contextId: String? = nil) async throws {
        let path =
            contextId.map { "/admin-api/contexts/sync/\($0)" } ?? "/admin-api/contexts/sync"
        try await http.sendVoid(jsonRequest(path, method: .post, body: EmptyObject()))
    }

    /// Kick off a full state re-pull for a context (operator recovery for a
    /// stranded context). `force` re-pulls even when the node does not flag the
    /// context as stranded.
    public func resyncContext(
        _ contextId: String, request: ResyncContextRequest = ResyncContextRequest()
    ) async throws -> ResyncContextResponseData {
        // Core's `ResyncContextApiResponse` is a flat payload (no inner `data`
        // field), so parse the body directly — do NOT unwrap. An empty 2xx body
        // means the resync was accepted; synthesize the result so callers always
        // get a typed value instead of null.
        let req = try jsonRequest("/admin-api/contexts/\(contextId)/resync", method: .post, body: request)
        let (data, _) = try await http.sendRaw(req)
        if let r = try? Self.decoder.decode(ResyncContextResponseData.self, from: data) { return r }
        return ResyncContextResponseData(contextId: contextId, resyncStarted: true)
    }

    /// Run a contract method under a warrant instead of the caller's own
    /// membership — the write path for a keyholder with no node.
    public func performIntent(
        _ contextId: String, request: PerformIntentRequest
    ) async throws -> PerformIntentResponseData {
        let resp: ApiResponse<PerformIntentResponseData> = try await http.post(
            "/admin-api/contexts/\(contextId)/intents", json: request)
        return try unwrap(resp, "performIntent")
    }

    public func updateContextApplication(_ contextId: String, request: UpdateContextApplicationRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/contexts/\(contextId)/application", method: .post, body: request))
    }

    public func getContextsWithExecutorsForApplication(
        _ applicationId: String
    ) async throws -> ContextsWithExecutorsResponseData {
        // Core returns this flat as { contexts: [...] } (not a bare array under `data`);
        // tolerate a bare array and the { data } envelope too.
        let (data, _) = try await http.sendRaw(
            HttpRequest(path: "/admin-api/contexts/with-executors/for-application/\(applicationId)"))
        if let arr = try? Self.decoder.decode([ContextWithExecutors].self, from: data) { return arr }
        struct Wrap: Decodable { let contexts: [ContextWithExecutors]?; let data: [ContextWithExecutors]? }
        if let w = try? Self.decoder.decode(Wrap.self, from: data) { return w.contexts ?? w.data ?? [] }
        return []
    }

    // MARK: - Blob Management

    public func uploadBlob(_ request: UploadBlobRequest) async throws -> UploadBlobResponseData {
        // Core streams the raw request body into blob storage (no JSON) and takes
        // its params from the query string (`hash`, `context_id` — snake_case).
        var query: [String] = []
        if let hash = request.hash { query.append("hash=\(hash.percentEncoded())") }
        if let contextId = request.contextId { query.append("context_id=\(contextId.percentEncoded())") }
        let path = query.isEmpty ? "/admin-api/blobs" : "/admin-api/blobs?" + query.joined(separator: "&")
        // Body is streamed verbatim as octet-stream. Core's BlobInfo is snake_case
        // (`blob_id`); map to camelCase like deleteBlob.
        let req = HttpRequest(
            path: path, method: .put, body: .data(request.data, contentType: "application/octet-stream"))
        let (data, _) = try await http.sendRaw(req)
        let resp = try Self.decoder.decode(ApiResponse<BlobWire>.self, from: data)
        let inner = try unwrap(resp, "uploadBlob")
        return BlobInfo(blobId: inner.blobId, size: inner.size)
    }

    public func deleteBlob(_ blobId: String) async throws -> DeleteBlobResponseData {
        // Core's `BlobDeleteResponse` is a flat, snake_case payload (`{ blob_id,
        // deleted }`) — parse directly (no unwrap) and map to camelCase.
        let wire: DeleteBlobWire = try await http.delete("/admin-api/blobs/\(blobId)")
        return DeleteBlobResponseData(blobId: wire.blobId, deleted: wire.deleted)
    }

    public func listBlobs() async throws -> ListBlobsResponseData {
        // Core's BlobInfo is snake_case (`blob_id`); map to camelCase.
        let resp: ApiResponse<BlobsWire> = try await http.get("/admin-api/blobs")
        let inner = try unwrap(resp, "listBlobs")
        return ListBlobsResponseData(blobs: inner.blobs.map { BlobInfo(blobId: $0.blobId, size: $0.size) })
    }

    /// Download a blob's raw bytes. `GET /admin-api/blobs/:id` streams the blob
    /// content (e.g. `application/gzip`), NOT JSON. Use `listBlobs` for
    /// `{ blobId, size }` metadata.
    public func getBlob(_ blobId: String) async throws -> Data {
        let (data, _) = try await http.sendRaw(HttpRequest(path: "/admin-api/blobs/\(blobId)"))
        return data
    }

    /// Fetch a blob's metadata without downloading it. `HEAD /admin-api/blobs/:id`
    /// returns the info in response headers (size via `content-length`, plus
    /// `x-blob-id`/`x-blob-hash`/`x-blob-mime-type`). Header names are lowercased.
    public func getBlobInfo(_ blobId: String) async throws -> GetBlobInfoResponseData {
        let result = try await http.head("/admin-api/blobs/\(blobId)", headers: [:])
        let size = Int(result.headers["content-length"] ?? "") ?? 0
        return GetBlobInfoResponseData(
            blobId: result.headers["x-blob-id"] ?? blobId,
            size: size,
            hash: result.headers["x-blob-hash"],
            mimeType: result.headers["x-blob-mime-type"]
        )
    }

    // MARK: - Alias Management

    public func createContextAlias(_ request: CreateContextAliasRequest) async throws -> CreateAliasResponseData {
        let resp: ApiResponse<CreateAliasResponseData> = try await http.post(
            "/admin-api/alias/create/context", json: request)
        return try emptyOK(resp, "createContextAlias")
    }

    public func createApplicationAlias(_ request: CreateApplicationAliasRequest) async throws -> CreateAliasResponseData
    {
        let resp: ApiResponse<CreateAliasResponseData> = try await http.post(
            "/admin-api/alias/create/application", json: request)
        return try emptyOK(resp, "createApplicationAlias")
    }

    public func lookupContextAlias(_ name: String) async throws -> LookupAliasResponseData {
        let resp: ApiResponse<LookupAliasResponseData> = try await http.post(
            "/admin-api/alias/lookup/context/\(name.percentEncoded())", json: EmptyObject())
        return try unwrap(resp, "lookupContextAlias")
    }

    public func lookupApplicationAlias(_ name: String) async throws -> LookupAliasResponseData {
        let resp: ApiResponse<LookupAliasResponseData> = try await http.post(
            "/admin-api/alias/lookup/application/\(name.percentEncoded())", json: EmptyObject())
        return try unwrap(resp, "lookupApplicationAlias")
    }

    public func deleteContextAlias(_ name: String) async throws -> DeleteAliasResponseData {
        let resp: ApiResponse<DeleteAliasResponseData> = try await http.post(
            "/admin-api/alias/delete/context/\(name.percentEncoded())", json: EmptyObject())
        return try emptyOK(resp, "deleteContextAlias")
    }

    public func deleteApplicationAlias(_ name: String) async throws -> DeleteAliasResponseData {
        let resp: ApiResponse<DeleteAliasResponseData> = try await http.post(
            "/admin-api/alias/delete/application/\(name.percentEncoded())", json: EmptyObject())
        return try emptyOK(resp, "deleteApplicationAlias")
    }

    public func listContextAliases() async throws -> ListAliasesResponseData {
        let resp: ApiResponse<ListAliasesResponseData> = try await http.get("/admin-api/alias/list/context")
        return try unwrap(resp, "listContextAliases")
    }

    public func listApplicationAliases() async throws -> ListAliasesResponseData {
        let resp: ApiResponse<ListAliasesResponseData> = try await http.get("/admin-api/alias/list/application")
        return try unwrap(resp, "listApplicationAliases")
    }

    // MARK: - Device Aliases

    // ⚠️ These four replace a "context identity alias" family that called
    // `/admin-api/alias/*/identity/{contextId}[/{name}]`. Those routes do not
    // exist and never did: an alias scopes to a device, not to an identity
    // within a context. A live 0.11.0-rc.32 node answers all four with 404, and
    // rc.32 also deleted the optional two-segment extractor the handlers used to
    // carry, so there is nothing left that could ever have matched.

    public func listDeviceAliases() async throws -> ListAliasesResponseData {
        let resp: ApiResponse<ListAliasesResponseData> = try await http.get("/admin-api/alias/list/device")
        return try unwrap(resp, "listDeviceAliases")
    }

    public func createDeviceAlias(_ request: CreateDeviceAliasRequest) async throws -> CreateAliasResponseData {
        let resp: ApiResponse<CreateAliasResponseData> = try await http.post(
            "/admin-api/alias/create/device", json: request)
        return try emptyOK(resp, "createDeviceAlias")
    }

    public func lookupDeviceAlias(_ name: String) async throws -> LookupAliasResponseData {
        let resp: ApiResponse<LookupAliasResponseData> = try await http.post(
            "/admin-api/alias/lookup/device/\(name.percentEncoded())", json: EmptyObject())
        return try unwrap(resp, "lookupDeviceAlias")
    }

    public func deleteDeviceAlias(_ name: String) async throws -> DeleteAliasResponseData {
        let resp: ApiResponse<DeleteAliasResponseData> = try await http.post(
            "/admin-api/alias/delete/device/\(name.percentEncoded())", json: EmptyObject())
        return try emptyOK(resp, "deleteDeviceAlias")
    }

    // MARK: - Namespace Management

    public func listNamespaces() async throws -> ListNamespacesResponseData {
        let resp: ApiResponse<ListNamespacesResponseData> = try await http.get("/admin-api/namespaces")
        return try unwrap(resp, "listNamespaces")
    }

    public func getNamespace(_ namespaceId: String) async throws -> Namespace {
        let resp: ApiResponse<Namespace> = try await http.get("/admin-api/namespaces/\(namespaceId)")
        return try unwrap(resp, "getNamespace")
    }

    public func listNamespacesForApplication(_ applicationId: String) async throws -> ListNamespacesResponseData {
        let resp: ApiResponse<ListNamespacesResponseData> = try await http.get(
            "/admin-api/namespaces/for-application/\(applicationId)")
        return try unwrap(resp, "listNamespacesForApplication")
    }

    public func createNamespace(_ request: CreateNamespaceRequest) async throws -> CreateNamespaceResponseData {
        let resp: ApiResponse<CreateNamespaceResponseData> = try await http.post("/admin-api/namespaces", json: request)
        return try unwrap(resp, "createNamespace")
    }

    public func deleteNamespace(
        _ namespaceId: String, request: DeleteNamespaceRequest? = nil
    ) async throws -> DeleteNamespaceResponseData {
        // Core requires `Content-Type: application/json` on this DELETE even when the
        // body is empty, so always send a (possibly empty) JSON body.
        let resp: ApiResponse<DeleteNamespaceResponseData>
        if let request {
            resp = try await http.delete("/admin-api/namespaces/\(namespaceId)", json: request)
        } else {
            resp = try await http.delete("/admin-api/namespaces/\(namespaceId)", json: EmptyObject())
        }
        return try unwrap(resp, "deleteNamespace")
    }

    public func createNamespaceInvitation(
        _ namespaceId: String, request: CreateNamespaceInvitationRequest? = nil
    ) async throws -> CreateNamespaceInvitationResult {
        let resp: ApiResponse<CreateNamespaceInvitationResult>
        if let request {
            resp = try await http.post("/admin-api/namespaces/\(namespaceId)/invite", json: request)
        } else {
            resp = try await http.post("/admin-api/namespaces/\(namespaceId)/invite", json: EmptyObject())
        }
        return try unwrap(resp, "createNamespaceInvitation")
    }

    public func joinNamespace(
        _ namespaceId: String, request: JoinNamespaceRequest
    ) async throws -> JoinNamespaceResponseData {
        // Join can be slow (network sync); use the TS 65s timeout.
        let req = try jsonRequest(
            "/admin-api/namespaces/\(namespaceId)/join", method: .post, body: request, timeout: 65)
        let resp: ApiResponse<JoinNamespaceResponseData> = try await http.send(req)
        return try unwrap(resp, "joinNamespace")
    }

    /// Carry a joiner's signed membership op onto the DAG, as a node the
    /// invitation named in its `admitters`.
    ///
    /// `published` says the op reached the namespace topic — not that the join
    /// landed, which happens when peers apply it and this node neither performs
    /// nor waits for.
    ///
    /// Requires core 0.11.0-rc.29 or newer.
    public func admitJoin(
        _ namespaceId: String, request: AdmitJoinRequest
    ) async throws -> AdmitJoinResponseData {
        let resp: ApiResponse<AdmitJoinResponseData> = try await http.post(
            "/admin-api/namespaces/\(namespaceId)/admit", json: request)
        return try unwrap(resp, "admitJoin")
    }

    /// Revoke one of this account's devices in a namespace, rotating the group
    /// key where the device held one.
    public func revokeDevice(
        _ namespaceId: String, request: RevokeDeviceRequest
    ) async throws -> RevokeDeviceResponseData {
        let resp: ApiResponse<RevokeDeviceResponseData> = try await http.post(
            "/admin-api/namespaces/\(namespaceId)/account/revoke", json: request)
        return try unwrap(resp, "revokeDevice")
    }

    // MARK: - Account (devices, applications, pairing)
    //
    // These moved in core 0.11.0-rc.28: pairing used to be namespace-scoped
    // (`/namespaces/{id}/account/pair-*`) and is now account-scoped, because a
    // device is paired to an account once and then linked into namespaces.
    // `revokeDevice` above is the one that stayed per-namespace — revocation is
    // where the group key gets rotated.

    /// Begin pairing a new device to this account. The response's
    /// `confirmationCode` is shown on both devices so a person can compare them.
    public func accountPairInit(
        _ request: AccountPairInitRequest
    ) async throws -> PairDeviceInitResponseData {
        let resp: ApiResponse<PairDeviceInitResponseData> = try await http.post(
            "/admin-api/account/pair-init", json: request)
        return try unwrap(resp, "accountPairInit")
    }

    /// Finish pairing, returning the new device's credential.
    public func accountPairComplete(
        _ request: AccountPairCompleteRequest
    ) async throws -> PairDeviceCompleteResponseData {
        let resp: ApiResponse<PairDeviceCompleteResponseData> = try await http.post(
            "/admin-api/account/pair-complete", json: request)
        return try unwrap(resp, "accountPairComplete")
    }

    /// This account's devices, with what each is linked into.
    public func listAccountDevices() async throws -> [AccountDeviceEntry] {
        // Un-enveloped: `{ devices: [...] }`.
        let response: AccountDevicesResponse = try await http.get("/admin-api/account/devices")
        return response.devices
    }

    /// The applications this account holds, and the namespaces each appears in.
    public func listAccountApplications() async throws -> [AccountApplicationEntry] {
        // Un-enveloped: `{ applications: [...] }`.
        let response: AccountApplicationsResponse = try await http.get(
            "/admin-api/account/applications")
        return response.applications
    }

    /// Re-link an already-paired device into an account's namespaces — the
    /// repair path when a device holds a credential but not the group keys.
    ///
    /// `skipped` names the namespaces it deliberately left alone, each with a
    /// reason; a relink that "did nothing" is usually a full `skipped` list, not
    /// a failure.
    public func relinkDevice(
        _ deviceId: String, request: RelinkDeviceRequest = RelinkDeviceRequest()
    ) async throws -> RelinkDeviceResponseData {
        let resp: ApiResponse<RelinkDeviceResponseData> = try await http.post(
            "/admin-api/account/devices/\(deviceId)/relink", json: request)
        return try unwrap(resp, "relinkDevice")
    }

    public func createGroupInNamespace(
        _ namespaceId: String, request: CreateGroupInNamespaceRequest? = nil
    ) async throws -> CreateGroupInNamespaceResponseData {
        let resp: ApiResponse<CreateGroupInNamespaceResponseData>
        if let request {
            resp = try await http.post("/admin-api/namespaces/\(namespaceId)/groups", json: request)
        } else {
            resp = try await http.post("/admin-api/namespaces/\(namespaceId)/groups", json: EmptyObject())
        }
        return try unwrap(resp, "createGroupInNamespace")
    }

    public func listNamespaceGroups(_ namespaceId: String) async throws -> [SubgroupEntry] {
        let resp: ApiResponse<[SubgroupEntry]> = try await http.get("/admin-api/namespaces/\(namespaceId)/groups")
        return try unwrap(resp, "listNamespaceGroups")
    }

    // MARK: - Group Management

    public func getGroupInfo(_ groupId: String) async throws -> GroupInfoResponseData {
        let resp: ApiResponse<GroupInfoResponseData> = try await http.get("/admin-api/groups/\(groupId)")
        return try unwrap(resp, "getGroupInfo")
    }

    /// Thin wrapper over `getGroupInfo`: returns the group's `defaultCapabilities` bitmask.
    public func getDefaultCapabilities(_ groupId: String) async throws -> Int {
        return try await getGroupInfo(groupId).defaultCapabilities
    }

    /// Thin wrapper over `getGroupInfo`: returns the group's `subgroupVisibility`.
    public func getSubgroupVisibility(_ groupId: String) async throws -> String {
        return try await getGroupInfo(groupId).subgroupVisibility
    }

    public func deleteGroup(
        _ groupId: String, request: DeleteGroupRequest? = nil
    ) async throws -> DeleteGroupResponseData {
        // Core requires `Content-Type: application/json` on this DELETE even with an
        // empty body, so always send a (possibly empty) JSON body.
        let resp: ApiResponse<DeleteGroupResponseData>
        if let request {
            resp = try await http.delete("/admin-api/groups/\(groupId)", json: request)
        } else {
            resp = try await http.delete("/admin-api/groups/\(groupId)", json: EmptyObject())
        }
        return try unwrap(resp, "deleteGroup")
    }

    /// Every member account in the group, and the devices each one holds.
    ///
    /// The listing that makes the account/device split usable. `listGroupMembers`
    /// reports device keys; every authorization subject is an account; and since
    /// rc.27 removed base58 the two are the same 64-hex shape, so nothing but
    /// provenance separates them. This is the mapping.
    public func listMemberDevices(
        _ groupId: String, offset: Int? = nil, limit: Int? = nil
    ) async throws -> [MemberDevicesEntry] {
        var query: [String] = []
        if let offset { query.append("offset=\(offset)") }
        if let limit { query.append("limit=\(limit)") }
        var path = "/admin-api/groups/\(groupId)/member-devices"
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        // Un-enveloped: core returns `{ members: [...] }` directly.
        let response: ListMemberDevicesResponseData = try await http.get(path)
        return response.members
    }

    public func listGroupMembers(_ groupId: String) async throws -> ListGroupMembersResponseData {
        // Response is un-enveloped ({ members, selfIdentity }). Validate the
        // non-optional `members` field so a contract-violating response surfaces
        // as a clear error rather than silently producing an empty list.
        let (data, _) = try await http.sendRaw(HttpRequest(path: "/admin-api/groups/\(groupId)/members"))
        struct Lenient: Decodable { let members: [GroupMember]?; let selfIdentity: String? }
        let lenient = try Self.decoder.decode(Lenient.self, from: data)
        guard let members = lenient.members else {
            // Sanitize before interpolation: keep untrusted bytes out of logs/UIs.
            let safeId = String(groupId.filter { !$0.isWhitespace }.prefix(64))
            throw MeroError.emptyResponse(
                "Invalid listGroupMembers response for group \(safeId): missing or non-array `members` field")
        }
        return ListGroupMembersResponseData(members: members, selfIdentity: lenient.selfIdentity)
    }

    public func listGroupContexts(_ groupId: String) async throws -> ListGroupContextsResponseData {
        let resp: ApiResponse<ListGroupContextsResponseData> = try await http.get(
            "/admin-api/groups/\(groupId)/contexts")
        return try unwrap(resp, "listGroupContexts")
    }

    public func addGroupMembers(_ groupId: String, request: AddGroupMembersRequest) async throws {
        try await http.sendVoid(jsonRequest("/admin-api/groups/\(groupId)/members", method: .post, body: request))
    }

    public func removeGroupMembers(_ groupId: String, request: RemoveGroupMembersRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/members/remove", method: .post, body: request))
    }

    public func updateMemberRole(_ groupId: String, identity: String, request: UpdateMemberRoleRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/members/\(identity)/role", method: .put, body: request))
    }

    public func getMemberCapabilities(_ groupId: String, identity: String) async throws -> MemberCapabilities {
        let resp: ApiResponse<MemberCapabilities> = try await http.get(
            "/admin-api/groups/\(groupId)/members/\(identity)/capabilities")
        return try unwrap(resp, "getMemberCapabilities")
    }

    public func setMemberCapabilities(
        _ groupId: String, identity: String, request: SetMemberCapabilitiesRequest
    ) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/members/\(identity)/capabilities", method: .put, body: request))
    }

    public func setDefaultCapabilities(_ groupId: String, request: SetDefaultCapabilitiesRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/settings/default-capabilities", method: .put, body: request))
    }

    public func setSubgroupVisibility(_ groupId: String, request: SetSubgroupVisibilityRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/settings/subgroup-visibility", method: .put, body: request))
    }

    public func setTeeAdmissionPolicy(_ groupId: String, request: SetTeeAdmissionPolicyRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/settings/tee-admission-policy", method: .put, body: request))
    }

    public func getTeeAdmissionPolicy(_ groupId: String) async throws -> GetTeeAdmissionPolicyResponseData {
        // `data` is optional so a flat (un-enveloped) response cleanly falls back.
        let (data, _) = try await http.sendRaw(
            HttpRequest(path: "/admin-api/groups/\(groupId)/settings/tee-admission-policy"))
        struct Env: Decodable { let data: GetTeeAdmissionPolicyResponseData? }
        if let env = try? Self.decoder.decode(Env.self, from: data), let d = env.data { return d }
        return try Self.decoder.decode(GetTeeAdmissionPolicyResponseData.self, from: data)
    }

    // MARK: - Group / member / context metadata

    public func setGroupMetadata(_ groupId: String, request: SetGroupMetadataRequest) async throws {
        try await http.sendVoid(jsonRequest("/admin-api/groups/\(groupId)/metadata", method: .put, body: request))
    }

    public func getGroupMetadata(_ groupId: String) async throws -> MetadataRecord? {
        return try await getMetadataRecord("/admin-api/groups/\(groupId)/metadata")
    }

    public func setMemberMetadata(_ groupId: String, identity: String, request: SetMemberMetadataRequest) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/members/\(identity)/metadata", method: .put, body: request))
    }

    public func getMemberMetadata(_ groupId: String, identity: String) async throws -> MetadataRecord? {
        return try await getMetadataRecord("/admin-api/groups/\(groupId)/members/\(identity)/metadata")
    }

    public func setContextMetadata(
        _ groupId: String, contextId: String, request: SetContextMetadataRequest
    ) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/contexts/\(contextId)/metadata", method: .put, body: request))
    }

    public func getContextMetadata(_ groupId: String, contextId: String) async throws -> MetadataRecord? {
        return try await getMetadataRecord("/admin-api/groups/\(groupId)/contexts/\(contextId)/metadata")
    }

    /// Core single-envelopes the record: `{ data: MetadataRecord | null }`.
    /// "No record yet" is `{ data: null }` (or a bare null body on older nodes),
    /// so resolve to a clean nil.
    private func getMetadataRecord(_ path: String) async throws -> MetadataRecord? {
        let (data, _) = try await http.sendRaw(HttpRequest(path: path))
        guard !data.isEmpty else { return nil }
        struct Env: Decodable { let data: MetadataRecord? }
        if let env = try? Self.decoder.decode(Env.self, from: data) { return env.data }
        return nil
    }

    public func syncGroup(_ groupId: String, request: SyncGroupRequest? = nil) async throws -> SyncGroupResponseData {
        let resp: ApiResponse<SyncGroupResponseData>
        if let request {
            resp = try await http.post("/admin-api/groups/\(groupId)/sync", json: request)
        } else {
            resp = try await http.post("/admin-api/groups/\(groupId)/sync", json: EmptyObject())
        }
        return try unwrap(resp, "syncGroup")
    }

    /// Initialize the contexts of a group you just joined so their state actually
    /// syncs, instead of sitting on the all-ones **"uninitialized" root hash**
    /// (`1111…`) you see right after joining a namespace/group but before the
    /// context data has been pulled. For each context in the group this triggers
    /// a group sync, joins the context (idempotent — gives this node a member
    /// identity), and triggers a per-context state pull.
    ///
    /// This is the step a client must run after ``joinNamespace(_:request:)`` /
    /// ``joinGroup(_:)`` for a joined space to become usable — otherwise the
    /// contexts can stay empty until something else forces a sync. It requires
    /// the joining node to (a) have the application installed and (b) be peered
    /// with a node that holds the state; if the context stays uninitialized after
    /// this, check the peer count (``getPeersCount()``).
    ///
    /// - Parameter groupId: the group/namespace whose contexts to initialize
    ///   (e.g. `joinNamespace(...).groupId`).
    /// - Returns: the group's contexts (after the sync attempt).
    @discardableResult
    public func syncGroupContexts(_ groupId: String) async throws -> ListGroupContextsResponseData {
        _ = try? await syncGroup(groupId)
        let contexts = try await listGroupContexts(groupId)
        for ctx in contexts {
            _ = try? await joinContext(ctx.contextId)
            try? await syncContext(ctx.contextId)
        }
        return contexts
    }

    public func upgradeGroup(_ groupId: String, request: UpgradeGroupRequest) async throws -> UpgradeGroupResponseData {
        let resp: ApiResponse<UpgradeGroupResponseData> = try await http.post(
            "/admin-api/groups/\(groupId)/upgrade", json: request)
        return try unwrap(resp, "upgradeGroup")
    }

    public func getGroupUpgradeStatus(_ groupId: String) async throws -> GroupUpgradeStatusResponseData {
        // Value is `GroupUpgradeStatus | null`; return the optional directly.
        let resp: ApiResponse<GroupUpgradeStatus> = try await http.get("/admin-api/groups/\(groupId)/upgrade/status")
        return resp.data
    }

    /// The operator-facing "have all peers migrated?" rollup for a namespace.
    /// The handler serializes the payload directly, so there is no `{ data }`
    /// envelope to unwrap here (unlike most admin reads).
    public func getMigrationStatus(_ namespaceId: String) async throws -> MigrationStatus {
        return try await http.get("/admin-api/groups/\(namespaceId.percentEncoded())/migration-status")
    }

    /// Per-group cascade-migration snapshots for a namespace.
    public func getCascadeStatus(_ namespaceId: String) async throws -> [CascadeStatusEntry] {
        let resp: ApiResponse<[CascadeStatusEntry]> = try await http.get(
            "/admin-api/groups/\(namespaceId.percentEncoded())/cascade-status")
        return try unwrap(resp, "getCascadeStatus")
    }

    public func retryGroupUpgrade(
        _ groupId: String, request: RetryGroupUpgradeRequest? = nil
    ) async throws -> RetryGroupUpgradeResponseData {
        let resp: ApiResponse<RetryGroupUpgradeResponseData>
        if let request {
            resp = try await http.post("/admin-api/groups/\(groupId)/upgrade/retry", json: request)
        } else {
            resp = try await http.post("/admin-api/groups/\(groupId)/upgrade/retry", json: EmptyObject())
        }
        return try unwrap(resp, "retryGroupUpgrade")
    }

    /// Move `childGroupId` under `request.newParentId`.
    public func reparentGroup(
        _ childGroupId: String, request: ReparentGroupRequest
    ) async throws -> ReparentGroupResponseData {
        // Core returns this flat ({ reparented }); tolerate the { data } envelope too.
        let req = try jsonRequest("/admin-api/groups/\(childGroupId)/reparent", method: .post, body: request)
        let (data, _) = try await http.sendRaw(req)
        struct Env: Decodable { let data: ReparentGroupResponseData?; let reparented: Bool? }
        let env = try Self.decoder.decode(Env.self, from: data)
        if let d = env.data { return d }
        return ReparentGroupResponseData(reparented: env.reparented ?? false)
    }

    public func listSubgroups(_ groupId: String) async throws -> [SubgroupEntry] {
        struct Wire: Codable, Sendable { let subgroups: [SubgroupEntry]?; let data: [SubgroupEntry]? }
        let wire: Wire = try await http.get("/admin-api/groups/\(groupId)/subgroups")
        return wire.subgroups ?? wire.data ?? []
    }

    public func detachContextFromGroup(
        _ groupId: String, contextId: String, request: DetachContextFromGroupRequest? = nil
    ) async throws {
        if let request {
            try await http.sendVoid(
                jsonRequest("/admin-api/groups/\(groupId)/contexts/\(contextId)/remove", method: .post, body: request))
        } else {
            try await http.sendVoid(
                jsonRequest(
                    "/admin-api/groups/\(groupId)/contexts/\(contextId)/remove", method: .post, body: EmptyObject()))
        }
    }

    // MARK: - Group Invitation & Join

    public func createGroupInvitation(
        _ groupId: String, request: CreateGroupInvitationRequest? = nil
    ) async throws -> CreateGroupInvitationResult {
        let resp: ApiResponse<CreateGroupInvitationResult>
        if let request {
            resp = try await http.post("/admin-api/groups/\(groupId)/invite", json: request)
        } else {
            resp = try await http.post("/admin-api/groups/\(groupId)/invite", json: EmptyObject())
        }
        return try unwrap(resp, "createGroupInvitation")
    }

    public func joinGroup(_ request: JoinGroupRequest) async throws -> JoinGroupResponseData {
        let resp: ApiResponse<JoinGroupResponseData> = try await http.post("/admin-api/groups/join", json: request)
        return try unwrap(resp, "joinGroup")
    }

    public func joinSubgroupInheritance(_ groupId: String) async throws -> JoinSubgroupInheritanceResponseData {
        let resp: ApiResponse<JoinSubgroupInheritanceResponseData> = try await http.post(
            "/admin-api/groups/\(groupId)/join-via-inheritance", json: EmptyObject())
        return try unwrap(resp, "joinSubgroupInheritance")
    }

    // MARK: - TEE

    public func getTeeInfo() async throws -> TeeInfoResponseData {
        let resp: ApiResponse<TeeInfoResponseData> = try await http.get("/admin-api/tee/info")
        return try unwrap(resp, "getTeeInfo")
    }

    public func teeAttest(_ request: TeeAttestRequest) async throws -> TeeAttestResponseData {
        let resp: ApiResponse<TeeAttestResponseData> = try await http.post("/admin-api/tee/attest", json: request)
        return try unwrap(resp, "teeAttest")
    }

    public func teeVerifyQuote(_ request: TeeVerifyQuoteRequest) async throws -> TeeVerifyQuoteResponseData {
        let resp: ApiResponse<TeeVerifyQuoteResponseData> = try await http.post(
            "/admin-api/tee/verify-quote", json: request)
        return try unwrap(resp, "teeVerifyQuote")
    }

    // MARK: - Network

    public func getPeersCount() async throws -> PeersCountResponseData {
        return try await http.get("/admin-api/peers")
    }

    /// Node network status (GET /admin-api/network/status).
    public func getNetworkStatus() async throws -> JSONValue {
        return try await rawJSON(HttpRequest(path: "/admin-api/network/status"))
    }

    /// Node storage/usage stats (GET /admin-api/usage).
    public func getUsage() async throws -> JSONValue {
        return try await rawJSON(HttpRequest(path: "/admin-api/usage"))
    }

    /// Node TLS certificate, PEM text (GET /admin-api/certificate).
    public func getCertificate() async throws -> String {
        let (data, _) = try await http.sendRaw(HttpRequest(path: "/admin-api/certificate"))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Group / context / namespace membership

    /// Create a standalone group (POST /admin-api/groups).
    public func createGroup(_ request: [String: JSONValue]) async throws -> CreateGroupResponseData {
        let resp: ApiResponse<CreateGroupResponseData> = try await http.post("/admin-api/groups", json: request)
        return try unwrap(resp, "createGroup")
    }

    /// Leave a group (POST /admin-api/groups/:group_id/leave).
    public func leaveGroup(_ groupId: String, request: [String: JSONValue]? = nil) async throws {
        try await http.sendVoid(jsonRequest("/admin-api/groups/\(groupId)/leave", method: .post, body: request ?? [:]))
    }

    /// Leave a context (POST /admin-api/contexts/:context_id/leave).
    public func leaveContext(_ contextId: String, request: [String: JSONValue]? = nil) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/contexts/\(contextId)/leave", method: .post, body: request ?? [:]))
    }

    /// Leave a namespace (POST /admin-api/namespaces/:namespace_id/leave).
    public func leaveNamespace(_ namespaceId: String, request: [String: JSONValue]? = nil) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/namespaces/\(namespaceId)/leave", method: .post, body: request ?? [:]))
    }

    /// Issue a group ownership proof (POST /admin-api/groups/:group_id/issue-ownership-proof).
    public func issueOwnershipProof(_ groupId: String, request: [String: JSONValue]? = nil) async throws -> JSONValue {
        return try await rawJSON(
            jsonRequest("/admin-api/groups/\(groupId)/issue-ownership-proof", method: .post, body: request ?? [:]))
    }

    /// Issue a namespace ownership proof (POST /admin-api/groups/:group_id/issue-namespace-ownership-proof).
    public func issueNamespaceOwnershipProof(
        _ groupId: String, request: [String: JSONValue]? = nil
    ) async throws -> JSONValue {
        return try await rawJSON(
            jsonRequest(
                "/admin-api/groups/\(groupId)/issue-namespace-ownership-proof", method: .post, body: request ?? [:]))
    }

    /// Set a member's auto-follow flag (PUT /admin-api/groups/:group_id/members/:identity/auto-follow).
    public func setMemberAutoFollow(_ groupId: String, identity: String, request: [String: JSONValue]) async throws {
        try await http.sendVoid(
            jsonRequest("/admin-api/groups/\(groupId)/members/\(identity)/auto-follow", method: .put, body: request))
    }

    /// Abort a namespace migration (POST /admin-api/groups/:namespace_id/migration/abort).
    public func abortMigration(_ namespaceId: String, request: [String: JSONValue]? = nil) async throws -> JSONValue {
        return try await rawJSON(
            jsonRequest("/admin-api/groups/\(namespaceId)/migration/abort", method: .post, body: request ?? [:]))
    }
}
