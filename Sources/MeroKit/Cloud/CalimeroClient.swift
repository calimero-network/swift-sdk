import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a ``CalimeroClient`` is built with. (== mero-js `CalimeroClientOptions`.)
public struct CalimeroClientOptions: Sendable {
    /// One node of the cluster: the one the client talks to first.
    public var baseUrl: String
    /// Other nodes of the same cluster, in the order to move to them when a
    /// node answers `421 WRONG_NODE`. Each is attested under the same
    /// ``policy`` before anything is sent to it. Without them a `421` reaches
    /// the caller as ``WrongNode``.
    public var nodes: [String]
    public var policy: CloudPolicy
    /// Carries the attestation and the sealed envelopes. (mero-js's `fetch`.)
    public var session: URLSession
    /// How calls and views retry a 503 or a failed connection.
    public var retry: CloudRetryOptions

    public init(
        baseUrl: String, nodes: [String] = [], policy: CloudPolicy, session: URLSession = .shared,
        retry: CloudRetryOptions = CloudRetryOptions()
    ) {
        self.baseUrl = baseUrl
        self.nodes = nodes
        self.policy = policy
        self.session = session
        self.retry = retry
    }
}

/// The client for Calimero 1.0, the confidential cloud: one app = one
/// replicated log on attested nodes. It verifies the node (``CloudPolicy``),
/// seals every request to it (``SealedTransport``), signs people in with
/// passkeys and machines with API keys. Port of mero-js `CalimeroClient`;
/// method names and semantics match it one for one.
///
/// ```swift
/// let cloud = CalimeroClient(CalimeroClientOptions(
///     baseUrl: "https://node.example", policy: CloudPolicy(release: CloudReleasePolicy(minReleaseVersion: "2.3.109"))))
/// try await cloud.signIn(PlatformPasskey())
/// let answer = try await cloud.call(appId, "set", ["key": "a", "value": "1"])
/// ```
///
/// - A `401` to a request that carried a session is answered by one refresh,
///   shared by every request that needs it at the same time (a refresh token
///   is used once), and the request is repeated once. A refused refresh
///   surfaces as ``LoginRequired``.
/// - `421 WRONG_NODE` moves the client to the next node it knows and repeats
///   the request once (not a sign-in or a refresh's ceremony: those are the
///   caller's, or ``refresh()``'s, to repeat). `421 NOT_LEADER` repeats it
///   once at `details.leaderUrl` when that is one of its nodes.
/// - Calls and views retry a `503` or a failed connection with the same
///   idempotency key (``CloudRetryOptions``).
public actor CalimeroClient {
    /// Every node this client may use, `baseUrl` first.
    public nonisolated let nodeUrls: [String]
    private var at = 0
    private var channels: [String: SealedTransport] = [:]
    private let policy: CloudPolicy
    private let urlSession: URLSession
    private let retry: CloudRetryOptions
    private var auth: String?
    private var current: CalimeroSession?
    private var refreshing: Task<CalimeroSession, Error>?
    private var refreshGeneration = 0
    private var sessionObserver: (@Sendable (CalimeroSession?) -> Void)?
    private let sleep: @Sendable (Double) async -> Void

    public init(_ options: CalimeroClientOptions) {
        self.init(options, sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) })
    }

    init(_ options: CalimeroClientOptions, sleep: @escaping @Sendable (Double) async -> Void) {
        var seen = Set<String>()
        nodeUrls = ([options.baseUrl] + options.nodes).map(Self.trim).filter { seen.insert($0).inserted }
        policy = options.policy
        urlSession = options.session
        retry = options.retry
        self.sleep = sleep
    }

    /// `baseUrl` with no trailing slash.
    static func trim(_ url: String) -> String {
        var out = url
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// The node requests go to now: `baseUrl`, until a `421 WRONG_NODE` moved the client on.
    public var nodeUrl: String { nodeUrls[at] }

    /// Call `observer` whenever the session changes: signed in, refreshed (a
    /// new refresh token, which replaces the stored one), or signed out
    /// (`nil`). A mobile app persists it from here. Not in mero-js, whose
    /// callers read ``session`` after each call.
    public func onSessionChange(_ observer: (@Sendable (CalimeroSession?) -> Void)?) {
        sessionObserver = observer
    }

    /// The sealed channel to `url`, attested under the client's policy before its first request.
    private func channel(_ url: String) throws -> SealedTransport {
        if let sealed = channels[url] { return sealed }
        guard let base = URL(string: url) else { throw TeeTrustError("bad node URL \(url)") }
        let policy = self.policy
        let session = urlSession
        let sealed = try SealedTransport(
            baseURL: base, key: .attest { try await fetchAttestedKey(url, policy: policy, session: session) },
            session: session)
        channels[url] = sealed
        return sealed
    }

    /// Move on from node `from` (the one that answered `421 WRONG_NODE`) to
    /// the next one. False when there is no other.
    private func moveOn(from: Int) -> Bool {
        guard nodeUrls.count > 1 else { return false }
        if at == from { at = (from + 1) % nodeUrls.count }
        return true
    }

    // MARK: - Credentials

    /// Authenticate every request with an API key (`cal_…`).
    public func useApiKey(_ key: String) {
        auth = key
        setCurrent(nil)
    }

    /// Authenticate every request with `session` (a stored one, say).
    public func useSession(_ session: CalimeroSession) {
        auth = session.sessionToken
        setCurrent(session)
    }

    /// The session in use, or `nil` (signed out, or an API key).
    public var session: CalimeroSession? { current }

    private func setCurrent(_ session: CalimeroSession?) {
        current = session
        sessionObserver?(session)
    }

    // MARK: - Sending

    /// One request to the node in use, with the credential held now; the
    /// response whatever its status.
    private func request(
        _ method: String, _ path: String, body: Data?, contentType: String
    ) async throws -> SealedResponse {
        let url = nodeUrl
        guard let target = URL(string: "\(url)/\(path)") else { throw AccountError.invalidInput("bad path \(path)") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        if let auth { request.setValue("Bearer \(auth)", forHTTPHeaderField: "authorization") }
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "content-type")
            request.httpBody = body
        }
        do {
            return try await channel(url).send(request)
        } catch let error as SealedTransportError where error.status == 413 {
            // The node refuses an envelope past its sealed cap in the clear,
            // before opening it: to the caller that is the API's `TOO_LARGE`.
            throw errorFrom(
                status: 413,
                body: [
                    "error": "TOO_LARGE",
                    "message": .string(error.message.replacingOccurrences(of: "Sealed request refused: ", with: "")),
                ])
        }
    }

    /// The ceremonies that mint a session, which ``send`` never repeats by
    /// itself. A node answers them `421 WRONG_NODE` before it spends the
    /// challenge or the refresh token.
    private static func ceremony(_ path: String) -> Bool {
        path == "auth/refresh" || path.hasPrefix("auth/passkey/")
    }

    /// ``request``, answering a lost issuing node, a node on the wrong
    /// release or a follower: a successful response, or the refusal as a
    /// typed error. (== mero-js `send`.)
    private func send(
        _ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json"
    ) async throws -> SealedResponse {
        var refreshed = false
        var moved = false
        var redirected = false
        while true {
            let token = auth
            let from = at
            let response = try await request(method, path, body: body, contentType: contentType)
            if (200..<300).contains(response.status) { return response }
            let error = errorFrom(
                status: response.status, data: (try? await response.data()) ?? Data(),
                retryAfter: response.headers["retry-after"])
            if error is WrongNode, !moved {
                moved = true
                if moveOn(from: from), !Self.ceremony(path) { continue }
            } else if let notLeader = error as? NotLeader, !redirected,
                let leader = notLeader.leaderUrl.map(Self.trim), let index = nodeUrls.firstIndex(of: leader)
            {
                redirected = true
                at = index
                continue
            } else if error is LoginRequired, !refreshed, let token, current != nil, !Self.ceremony(path) {
                refreshed = true
                // A refresh another request made already answers this one.
                if auth == token { _ = try await refresh() }
                continue
            }
            throw error
        }
    }

    private func json(
        _ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json"
    )
        async throws -> Data
    {
        let response = try await send(method, path, body: body, contentType: contentType)
        return try await response.data()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try MeroJSON.decode(type, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw AccountError.protocolViolation("the node's answer did not decode as \(T.self): \(error)")
        }
    }

    private func value(_ data: Data) throws -> JSONValue {
        try decode(JSONValue.self, data)
    }

    /// ``json`` for a call or a view: while the node answers 503 or cannot be
    /// reached, the same request, with the same idempotency key, is sent again
    /// after a backoff (or the pause the node asked for, if longer), at most
    /// `retries` times. The last failure surfaces as ``UnavailableError``.
    private func retried(_ path: String, body: Data, retries: Int? = nil) async throws -> Data {
        let limit = retries ?? retry.retries
        var attempt = 0
        while true {
            let unavailable: UnavailableError
            do {
                return try await json("POST", path, body: body)
            } catch let error as UnavailableError {
                unavailable = error
            } catch let error as URLError {
                unavailable = UnavailableError(
                    code: "NETWORK", message: "the node could not be reached: \(error.localizedDescription)",
                    cause: error)
            }
            if attempt >= limit { throw unavailable }
            await sleep(max(retry.delay(attempt), unavailable.retryAfter ?? 0))
            attempt += 1
        }
    }

    /// `POST path` with a JSON body; the answer as JSON.
    @discardableResult
    public func post(_ path: String, _ body: JSONValue = [:]) async throws -> JSONValue {
        try value(try await json("POST", path, body: CanonicalJSON.data(body)))
    }

    /// `GET path`; the answer as JSON.
    public func get(_ path: String) async throws -> JSONValue {
        try value(try await json("GET", path))
    }

    /// `PUT path` with a JSON body; the answer as JSON.
    @discardableResult
    public func put(_ path: String, _ body: JSONValue = [:]) async throws -> JSONValue {
        try value(try await json("PUT", path, body: CanonicalJSON.data(body)))
    }

    /// `DELETE path`, with a JSON body when given; the answer as JSON.
    @discardableResult
    public func delete(_ path: String, _ body: JSONValue? = nil) async throws -> JSONValue {
        try value(try await json("DELETE", path, body: body.map { CanonicalJSON.data($0) }))
    }

    // MARK: - Identity

    /// Create an account with a new passkey, and sign in.
    @discardableResult
    public func signUp(_ passkey: any PasskeyProvider, name: String) async throws -> CalimeroSession {
        let begin = try await post("auth/passkey/register/begin", ["name": .string(name)])
        guard let challengeId = begin["challengeId"]?.stringValue, let options = begin["options"] else {
            throw AccountError.protocolViolation("the registration did not begin")
        }
        let registration = try await passkey.create(options: options)
        let data = try await json(
            "POST", "auth/passkey/register/finish",
            body: CanonicalJSON.data(["challengeId": .string(challengeId), "registration": try Self.json(registration)])
        )
        let session = try decode(CalimeroSession.self, data)
        useSession(session)
        return session
    }

    /// Sign in with an existing passkey.
    @discardableResult
    public func signIn(_ passkey: any PasskeyProvider) async throws -> CalimeroSession {
        let begin = try await post("auth/passkey/login/begin")
        guard let challengeId = begin["challengeId"]?.stringValue,
            let challenge = begin["options"]?["challenge"]?.stringValue,
            let rpId = begin["options"]?["rpId"]?.stringValue
        else { throw AccountError.protocolViolation("the sign-in did not begin") }
        let assertion = try await passkey.get(challenge: try fromB64url(challenge), rpId: rpId, allowCredentials: nil)
        let data = try await json(
            "POST", "auth/passkey/login/finish",
            body: CanonicalJSON.data(["challengeId": .string(challengeId), "assertion": try Self.json(assertion)]))
        let session = try decode(CalimeroSession.self, data)
        useSession(session)
        return session
    }

    /// Swap the refresh token for a new session, on whichever node the client
    /// uses. A refresh token is used once, so calls made while one refresh is
    /// under way share it rather than sending the same token again (which
    /// would revoke the session).
    @discardableResult
    public func refresh() async throws -> CalimeroSession {
        if let refreshing { return try await refreshing.value }
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { try await self.exchangeRefresh() }
        refreshing = task
        defer { if refreshGeneration == generation { refreshing = nil } }
        return try await task.value
    }

    private func exchangeRefresh() async throws -> CalimeroSession {
        guard let current else { throw LoginRequired("no session to refresh") }
        // A node that may not serve the account answers `421 WRONG_NODE`
        // before it spends the refresh token, so the same token goes to the
        // next node (`send` moved there already): once per node, at most.
        var tried = 1
        while true {
            do {
                let data = try await json(
                    "POST", "auth/refresh", body: CanonicalJSON.data(["refreshToken": .string(current.refreshToken)]))
                let session = try decode(CalimeroSession.self, data)
                // A sign-in or another session taken while this one was refreshing wins.
                if self.current == current { useSession(session) }
                return session
            } catch let error as WrongNode {
                if tried >= nodeUrls.count { throw error }
                tried += 1
            }
        }
    }

    /// End this session.
    public func signOut() async throws {
        try await post("auth/logout")
        auth = nil
        setCurrent(nil)
    }

    /// End every session of the signed-in account, on every device, this one too.
    public func signOutEverywhere() async throws {
        try await post("auth/logout-all")
        auth = nil
        setCurrent(nil)
    }

    /// Forget the credential without telling the node (it is unreachable, say).
    public func forget() {
        auth = nil
        setCurrent(nil)
    }

    /// `GET /auth/me`: the account, its passkeys and its organizations.
    public func me() async throws -> AccountInfo {
        AccountInfo(json: try await get("auth/me"))
    }

    /// Add another passkey (another device) to the signed-in account; answers its credential id.
    public func addPasskey(_ passkey: any PasskeyProvider) async throws -> String {
        let begin = try await post("auth/passkeys/add/begin")
        guard let challengeId = begin["challengeId"]?.stringValue, let options = begin["options"] else {
            throw AccountError.protocolViolation("adding a passkey did not begin")
        }
        let registration = try await passkey.create(options: options)
        let finished = try await post(
            "auth/passkeys/add/finish",
            ["challengeId": .string(challengeId), "registration": try Self.json(registration)])
        return finished["credentialId"]?.stringValue ?? ""
    }

    /// Remove one of the account's passkeys (not the last).
    public func removePasskey(_ credentialId: String) async throws {
        try await delete("auth/passkeys/\(Self.seg(credentialId))")
    }

    /// Name one of the account's passkeys; `""` clears the name.
    public func labelPasskey(_ credentialId: String, label: String) async throws {
        try await post("auth/passkeys/\(Self.seg(credentialId))", ["label": .string(label)])
    }

    /// What this account uses, with the cluster's quotas.
    public func usage() async throws -> JSONValue {
        try await get("auth/usage")
    }

    /// The node's attestation document, unverified: for display only. Every
    /// request this client sends is sealed to a key it verified itself first.
    public func attestation() async throws -> AttestationDoc {
        guard let url = URL(string: "\(nodeUrl)/attestation?nonce=\(Hex.encode(randomBytes(32)))") else {
            throw TeeTrustError("bad node URL \(nodeUrl)")
        }
        let (data, response) = try await urlSession.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw errorFrom(status: status, data: data) }
        return try decode(AttestationDoc.self, data)
    }

    /// The account's API keys (never the keys themselves).
    public func listApiKeys() async throws -> [JSONValue] {
        try await get("auth/apikeys")["keys"]?.arrayValue ?? []
    }

    public func revokeApiKey(_ keyId: String) async throws {
        try await delete("auth/apikeys/\(Self.seg(keyId))")
    }

    /// Create an API key for an agent or server. The key is returned once.
    public func createApiKey(
        label: String? = nil, apps: [String]? = nil, methods: [String]? = nil, readOnly: Bool? = nil,
        allowConfirm: Bool? = nil, ttlSecs: Int? = nil
    ) async throws -> (keyId: String, key: String) {
        var body: [String: JSONValue] = [:]
        if let label { body["label"] = .string(label) }
        if let apps { body["apps"] = .array(apps.map { .string($0) }) }
        if let methods { body["methods"] = .array(methods.map { .string($0) }) }
        if let readOnly { body["readOnly"] = .bool(readOnly) }
        if let allowConfirm { body["allowConfirm"] = .bool(allowConfirm) }
        if let ttlSecs { body["ttlSecs"] = .number(Double(ttlSecs)) }
        let answer = try await post("auth/apikeys", .object(body))
        return (answer["keyId"]?.stringValue ?? "", answer["key"]?.stringValue ?? "")
    }

    // MARK: - Bundles and blobs

    /// Upload a raw WASM bundle (development clusters only); answers its hash.
    public func uploadBundle(_ wasm: Data) async throws -> String {
        let answer = try value(try await json("POST", "bundles", body: wasm, contentType: "application/wasm"))
        return answer["hash"]?.stringValue ?? ""
    }

    /// Upload a blob for `app`: `blobId` is base58 (what apps print), `id` hex.
    public func uploadBlob(_ app: String, _ data: Data) async throws -> BlobInfo {
        try decode(
            BlobInfo.self,
            try await json("POST", "apps/\(Self.seg(app))/blobs", body: data, contentType: "application/octet-stream"))
    }

    /// One of `app`'s blobs, by id (base58 or hex).
    public func downloadBlob(_ app: String, _ id: String) async throws -> Data {
        try await json("GET", "apps/\(Self.seg(app))/blobs/\(Self.seg(id))")
    }

    /// `app`'s blobs.
    public func listBlobs(_ app: String) async throws -> [BlobInfo] {
        let answer = try await json("GET", "apps/\(Self.seg(app))/blobs")
        return try decode(BlobList.self, answer).blobs
    }

    /// One of `app`'s blobs' id and size; ``NotFound`` if the app has no such blob.
    public func blobInfo(_ app: String, _ id: String) async throws -> BlobInfo {
        try decode(BlobInfo.self, try await json("GET", "apps/\(Self.seg(app))/blobs/\(Self.seg(id))/info"))
    }

    /// Delete one of `app`'s blobs (its owner, or an admin of its organization).
    public func deleteBlob(_ app: String, _ id: String) async throws {
        try await delete("apps/\(Self.seg(app))/blobs/\(Self.seg(id))")
    }

    // MARK: - Packages

    /// Install a signed `.mpk` package file (development clusters only).
    public func uploadPackage(_ mpk: Data) async throws -> PackageInstalled {
        try decode(
            PackageInstalled.self,
            try await json("POST", "packages", body: mpk, contentType: "application/octet-stream"))
    }

    /// Install `package@version` from the cluster's registry.
    public func installPackage(_ package: String, version: String) async throws -> PackageInstalled {
        let body = CanonicalJSON.data(["package": .string(package), "version": .string(version)])
        return try decode(PackageInstalled.self, try await json("POST", "packages/install", body: body))
    }

    /// Installed packages and their versions.
    public func packages() async throws -> [PackageInfo] {
        try decode(PackageList.self, try await json("GET", "packages")).packages
    }

    /// One installed package and its versions.
    public func package(_ package: String) async throws -> PackageInfo {
        try decode(PackageInfo.self, try await json("GET", "packages/\(Self.seg(package))"))
    }

    /// Uninstall one version, or the whole package. Refused while an app runs it.
    @discardableResult
    public func uninstallPackage(_ package: String, version: String? = nil) async throws -> JSONValue {
        try await delete(
            version.map { "packages/\(Self.seg(package))/\(Self.seg($0))" } ?? "packages/\(Self.seg(package))")
    }

    // MARK: - App instances

    /// Apps this caller reaches, optionally only those of one package or bundle.
    public func listApps(package: String? = nil, bundle: String? = nil) async throws -> [AppInfo] {
        var query: [String] = []
        if let package { query.append("package=\(Self.queryValue(package))") }
        if let bundle { query.append("bundle=\(Self.queryValue(bundle))") }
        let path = query.isEmpty ? "apps" : "apps?" + query.joined(separator: "&")
        return try decode(AppList.self, try await json("GET", path)).apps
    }

    /// The app's record: `name`, `owner`, `org`, `access`, `metadata`, `bundle`, ….
    public func getApp(_ app: String) async throws -> JSONValue {
        try await get("apps/\(Self.seg(app))")
    }

    /// Delete an app instance (its owner, or an admin of its organization).
    public func deleteApp(_ app: String) async throws {
        try await delete("apps/\(Self.seg(app))")
    }

    /// Who may reach the app.
    public func setAccess(_ app: String, _ access: AppAccess) async throws {
        try await post("apps/\(Self.seg(app))/access", ["access": access.json])
    }

    /// Set the app instance's metadata; at most 16 KiB.
    public func setAppMetadata(_ app: String, _ metadata: JSONValue) async throws {
        try await post("apps/\(Self.seg(app))/metadata", ["metadata": metadata])
    }

    /// What the app's storage holds: `{ keys, bytes, blobs, blobBytes }`.
    public func appStorage(_ app: String) async throws -> JSONValue {
        try await get("apps/\(Self.seg(app))/storage")
    }

    /// The ABI the app's bundle embeds: `{ bundle, abi }`.
    public func appAbi(_ app: String) async throws -> JSONValue {
        try await get("apps/\(Self.seg(app))/abi")
    }

    /// Hand the app to another account. The owner approves with `passkey`.
    public func transferApp(_ app: String, to: String, passkey: any PasskeyProvider) async throws {
        _ = try await postConfirmed("apps/\(Self.seg(app))/transfer", ["to": .string(to)], passkey: passkey)
    }

    /// Move an app to another release of its package (`version`), another
    /// package, or a bundle hash, running its migration. Where the node asks
    /// for an approval (`412 CONFIRM_REQUIRED`), `passkey` gives it.
    @discardableResult
    public func upgradeApp(
        _ app: String, version: String? = nil, package: String? = nil, service: String? = nil, bundle: String? = nil,
        migrate: String? = nil, passkey: (any PasskeyProvider)? = nil
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = [:]
        for (key, value) in [
            ("version", version), ("package", package), ("service", service), ("bundle", bundle), ("migrate", migrate),
        ] {
            if let value { body[key] = .string(value) }
        }
        let path = "apps/\(Self.seg(app))/upgrade"
        if let passkey { return try await postConfirmed(path, .object(body), passkey: passkey) }
        return try await post(path, .object(body))
    }

    /// POST `body` to `path`, answering a `412 CONFIRM_REQUIRED` with
    /// `passkey`'s assertion over the node's challenge.
    @discardableResult
    public func postConfirmed(_ path: String, _ body: JSONValue, passkey: any PasskeyProvider) async throws -> JSONValue
    {
        try value(
            try await confirmed(body, passkey: passkey) { body in
                try await self.json("POST", path, body: CanonicalJSON.data(body))
            })
    }

    /// ``postConfirmed(_:_:passkey:)`` for a DELETE (deleting an organization).
    @discardableResult
    public func deleteConfirmed(
        _ path: String, passkey: any PasskeyProvider, body: JSONValue = [:]
    ) async throws
        -> JSONValue
    {
        try value(
            try await confirmed(body, passkey: passkey) { body in
                try await self.json("DELETE", path, body: CanonicalJSON.data(body))
            })
    }

    private func confirmed(
        _ body: JSONValue, passkey: any PasskeyProvider, send: @Sendable (JSONValue) async throws -> Data
    ) async throws -> Data {
        do {
            return try await send(body)
        } catch let required as ConfirmRequired {
            let d = required.details
            guard let challengeId = d["challengeId"]?.stringValue, let challenge = d["challenge"]?.stringValue,
                let rpId = d["rpId"]?.stringValue
            else { throw required }
            let assertion: AssertionJSON
            do {
                assertion = try await passkey.get(
                    challenge: try fromB64url(challenge), rpId: rpId,
                    allowCredentials: d["allowCredentials"]?.arrayValue?.compactMap(\.stringValue))
            } catch let cancelled as PasskeyCancelled {
                throw ConfirmCancelled(cause: cancelled.message)
            }
            var confirmedBody = body.objectValue ?? [:]
            confirmedBody["confirm"] = ["challengeId": .string(challengeId), "assertion": try Self.json(assertion)]
            return try await send(.object(confirmedBody))
        }
    }

    /// Create an app instance from a bundle hash, or from a package release
    /// (installed from the registry first if the cluster lacks it). Answers its app id.
    public func createApp(
        _ name: String, bundle: AppSource, org: String? = nil, access: AppAccess? = nil,
        confirmMethods: [String]? = nil, initArgs: JSONValue? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = ["name": .string(name)]
        switch bundle {
        case .bundle(let hash): body["bundle"] = .string(hash)
        case .package(let package, let version, let service):
            body["package"] = .string(package)
            if let version { body["version"] = .string(version) }
            if let service { body["service"] = .string(service) }
        }
        if let org { body["org"] = .string(org) }
        if let access { body["access"] = access.json }
        if let confirmMethods { body["confirmMethods"] = .array(confirmMethods.map { .string($0) }) }
        if let initArgs { body["initArgs"] = initArgs }
        let answer = try await post("apps", .object(body))
        guard let appId = answer["appId"]?.stringValue else {
            throw AccountError.protocolViolation("the node created no app")
        }
        return appId
    }

    /// Call a method. A retry with the same `idempotencyKey` is answered
    /// once. Without one, the client makes one, so its own retries of a 503 share it.
    public func call(
        _ app: String, _ method: String, _ args: JSONValue = [:], idempotencyKey: String? = nil
    )
        async throws -> CallResult
    {
        try decode(
            CallResult.self,
            try await callJSON(app, method, argsJSON: CanonicalJSON.data(args), idempotencyKey: idempotencyKey))
    }

    /// ``call(_:_:_:idempotencyKey:)`` with JSON bytes in and the whole answer
    /// out, every number kept as written (a `u64` beyond 2^53).
    public func callJSON(
        _ app: String, _ method: String, argsJSON: Data, idempotencyKey: String? = nil
    )
        async throws -> Data
    {
        let key = idempotencyKey ?? Self.newIdempotencyKey()
        return try await retried(
            "apps/\(Self.seg(app))/intents", body: try Self.body(method: method, argsJSON: argsJSON, key: key))
    }

    /// Call a method that needs the account holder's approval: the node
    /// returns a challenge over this exact call, which `passkey` signs. A
    /// declined prompt throws ``ConfirmCancelled``.
    public func callConfirmed(
        _ app: String, _ method: String, _ args: JSONValue, passkey: any PasskeyProvider, idempotencyKey: String? = nil
    ) async throws -> CallResult {
        let path = "apps/\(Self.seg(app))/intents"
        let key = idempotencyKey ?? Self.newIdempotencyKey()
        let body: JSONValue = ["method": .string(method), "args": args, "idempotencyKey": .string(key)]
        // The confirmed attempt goes out exactly once: its challenge is single-use.
        let data = try await confirmed(body, passkey: passkey) { body in
            try await self.retried(path, body: CanonicalJSON.data(body), retries: body["confirm"] == nil ? nil : 0)
        }
        return try decode(CallResult.self, data)
    }

    /// Run a read-only method: strong by default, or stale from any replica.
    public func view(
        _ app: String, _ method: String, _ args: JSONValue = [:], stale: Bool = false, minIndex: Int = 0
    )
        async throws -> ViewResult
    {
        try decode(
            ViewResult.self,
            try await viewJSON(app, method, argsJSON: CanonicalJSON.data(args), stale: stale, minIndex: minIndex))
    }

    /// ``view(_:_:_:stale:minIndex:)`` with JSON bytes in and the whole answer out.
    public func viewJSON(
        _ app: String, _ method: String, argsJSON: Data, stale: Bool = false, minIndex: Int = 0
    )
        async throws -> Data
    {
        let args = try LiteralJSON.write(LiteralJSON.parse(argsJSON.isEmpty ? Data("{}".utf8) : argsJSON))
        let body =
            "{\"args\":\(args),\"consistency\":\(stale ? "\"stale\"" : "\"strong\""),"
            + "\"method\":\(CanonicalJSON.quote(method)),\"minIndex\":\(minIndex)}"
        return try await retried("apps/\(Self.seg(app))/views", body: Data(body.utf8))
    }

    /// Committed events from index `from`, then live, until the stream is
    /// cancelled (stop iterating, or cancel the task).
    public nonisolated func events(_ app: String, from: Int = 0) -> AsyncThrowingStream<CloudEvent, Error> {
        stream("apps/\(Self.seg(app))/events?from=\(from)")
    }

    /// A server-sent event stream on `path`, sealed like every other answer.
    private nonisolated func stream(_ path: String) -> AsyncThrowingStream<CloudEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.send("GET", path)
                    var parser = SseParser()
                    for try await chunk in response.body {
                        for event in parser.feed(chunk) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Presence

    /// Publish this device's presence in `app`: `state` (at most 4 KiB) or
    /// `nil` to retract it. Send the same `seq` and state again as a
    /// heartbeat: an entry not refreshed within 7 s is gone.
    public func publishPresence(_ app: String, seq: Int, state: Data?) async throws {
        try await post(
            "apps/\(Self.seg(app))/presence",
            ["seq": .number(Double(seq)), "state": state.map { .string(Hex.encode($0)) } ?? .null])
    }

    /// Who is present in `app` now.
    public func presence(_ app: String) async throws -> [PresenceEntry] {
        try decode(PresenceList.self, try await json("GET", "apps/\(Self.seg(app))/presence")).present
    }

    /// Presence as a stream: a `snapshot` event, then a `presence` event per change.
    public nonisolated func presenceStream(_ app: String) -> AsyncThrowingStream<CloudEvent, Error> {
        stream("apps/\(Self.seg(app))/presence/stream")
    }

    // MARK: - Aliases

    /// Name an app for this account.
    public func setAlias(_ alias: String, app: String) async throws {
        try await put("auth/aliases/\(Self.seg(alias))", ["app": .string(app)])
    }

    /// This account's aliases, alias → app id.
    public func aliases() async throws -> [String: String] {
        (try await get("auth/aliases")["aliases"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }

    /// The app an alias names.
    public func alias(_ alias: String) async throws -> String {
        try await get("auth/aliases/\(Self.seg(alias))")["appId"]?.stringValue ?? ""
    }

    public func deleteAlias(_ alias: String) async throws {
        try await delete("auth/aliases/\(Self.seg(alias))")
    }

    // MARK: - Organizations

    /// Create an organization; answers its id.
    public func createOrg(_ name: String) async throws -> String {
        try await post("orgs", ["name": .string(name)])["orgId"]?.stringValue ?? ""
    }

    /// The organization, with the teams this caller reaches or manages.
    public func getOrg(_ org: String) async throws -> OrgInfo {
        OrgInfo(json: try await get("orgs/\(Self.seg(org))"))
    }

    /// Delete an organization with its teams, invites and apps (its owner, with `passkey`).
    public func deleteOrg(_ org: String, passkey: any PasskeyProvider) async throws {
        try await deleteConfirmed("orgs/\(Self.seg(org))", passkey: passkey)
    }

    /// Set the organization's metadata; at most 16 KiB.
    public func setOrgMetadata(_ org: String, _ metadata: JSONValue) async throws {
        try await post("orgs/\(Self.seg(org))/metadata", ["metadata": metadata])
    }

    /// Set a member's metadata (theirs, or an admin's); `.null` clears it.
    public func setMemberMetadata(_ org: String, account: String, _ metadata: JSONValue) async throws {
        try await post("orgs/\(Self.seg(org))/members/\(Self.seg(account))/metadata", ["metadata": metadata])
    }

    /// Upgrade every app of `org` that runs `target.package`, approved with `passkey`.
    public func upgradeOrg(
        _ org: String, _ target: OrgUpgradeTarget, passkey: any PasskeyProvider
    ) async throws
        -> UpgradeRun
    {
        let body = try MeroJSON.decode(JSONValue.self, from: try MeroJSON.encode(target))
        return try decode(
            UpgradeRun.self,
            CanonicalJSON.data(try await postConfirmed("orgs/\(Self.seg(org))/upgrade", body, passkey: passkey)))
    }

    /// An organization-wide upgrade run.
    public func upgradeRun(_ org: String, _ run: String) async throws -> UpgradeRun {
        try decode(UpgradeRun.self, try await json("GET", "orgs/\(Self.seg(org))/upgrades/\(Self.seg(run))"))
    }

    /// Run the apps that failed in `run` again, as a new run, approved with `passkey`.
    public func retryUpgradeRun(_ org: String, _ run: String, passkey: any PasskeyProvider) async throws -> UpgradeRun {
        let answer = try await postConfirmed(
            "orgs/\(Self.seg(org))/upgrades/\(Self.seg(run))/retry", [:], passkey: passkey)
        return try decode(UpgradeRun.self, CanonicalJSON.data(answer))
    }

    /// Approve a mero-tee release for `org`'s apps, or this account's own
    /// (`org` `nil`); `approved: false` withdraws it. Refused to a session
    /// opened on an app's frontend: ask with ``requestConsent(_:)`` instead.
    @discardableResult
    public func approveRelease(
        _ org: String?, version: String, passkey: any PasskeyProvider, approved: Bool = true
    )
        async throws -> JSONValue
    {
        let path = org.map { "orgs/\(Self.seg($0))/releases" } ?? "auth/releases"
        return try await postConfirmed(
            path, ["version": .string(version), "approved": .bool(approved)], passkey: passkey)
    }

    /// Approve the URL prefixes apps from `package`'s publisher may call out
    /// to; `prefixes` `nil` approves every prefix the package's latest
    /// release declares; `replace` sets exactly `prefixes`.
    @discardableResult
    public func approveOutbound(
        _ org: String?, package: String, passkey: any PasskeyProvider, prefixes: [String]? = nil, replace: Bool = false
    ) async throws -> JSONValue {
        let path = org.map { "orgs/\(Self.seg($0))/outbound" } ?? "auth/outbound"
        return try await postConfirmed(
            path,
            [
                "package": .string(package), "prefixes": prefixes.map { .array($0.map { .string($0) }) } ?? "manifest",
                "replace": .bool(replace),
            ], passkey: passkey)
    }

    // MARK: - Approvals

    /// One page of the report of a scope's apps.
    public func appsReport(_ org: String?, page: PageOptions = PageOptions()) async throws -> AppsReport {
        let path = org.map { "orgs/\(Self.seg($0))/apps" } ?? "auth/apps"
        return try decode(AppsReport.self, try await json("GET", path + (try page.query())))
    }

    /// ``appsReport(_:page:)``, every page, with the apps of all of them in `apps`.
    public func appsReportAll(_ org: String?) async throws -> AppsReport {
        var report = try await appsReport(org)
        var next = report.next
        while let after = next {
            let page = try await appsReport(org, page: PageOptions(after: after))
            report.apps += page.apps
            next = page.next
        }
        report.next = nil
        return report
    }

    /// `GET /releases`: the cluster's governance and every release deadline.
    public func releaseRules() async throws -> ReleaseRules {
        try decode(ReleaseRules.self, try await json("GET", "releases"))
    }

    /// What waits for a decision in a scope (`org`, or the account's own apps with `nil`).
    public func pendingApprovals(org: String? = nil) async throws -> PendingApprovals {
        async let report = appsReportAll(org)
        async let rules = releaseRules()
        return pendingApprovalsFrom(try await report, rules: try await rules)
    }

    /// Ask the node to ask the user: an approval decided on the node's own
    /// consent page, never in the app. Send the person to the answer's `url`
    /// (`MeroKitUI`'s `ConsentPage` opens it in the system browser).
    public func requestConsent(_ request: ConsentRequest) async throws -> ConsentStarted {
        try decode(
            ConsentStarted.self, try await json("POST", "consent/requests", body: CanonicalJSON.data(request.json)))
    }

    /// ``requestConsent(_:)``, then hand the page's URL to `navigate`.
    /// (== mero-js `openConsentPage`, whose default navigates the window.)
    public func openConsentPage(
        _ request: ConsentRequest, navigate: @Sendable (URL) async throws -> Void
    ) async throws
        -> ConsentStarted
    {
        let started = try await requestConsent(request)
        guard let url = URL(string: started.url) else { throw AccountError.protocolViolation("bad consent URL") }
        try await navigate(url)
        return started
    }

    /// The decision on a consent request.
    public func consentResult(_ requestId: String) async throws -> ConsentResult {
        try decode(ConsentResult.self, try await json("GET", "consent/\(Self.seg(requestId))/result"))
    }

    /// Poll ``consentResult(_:)`` until the request is decided, every
    /// `interval` seconds, until the task is cancelled or `expiresAt` (Unix
    /// seconds) passes, when it answers the last `pending` result.
    public func waitForConsent(
        _ requestId: String, interval: Double = 2, expiresAt: Double? = nil
    ) async throws
        -> ConsentResult
    {
        while true {
            let result = try await consentResult(requestId)
            if result.status != .pending || Task.isCancelled { return result }
            if let expiresAt, Date().timeIntervalSince1970 >= expiresAt { return result }
            await sleep(interval)
        }
    }

    /// `GET /publishers/{signerId}`.
    public func publisherBinding(_ signerId: String) async throws -> PublisherBindingInfo {
        try decode(PublisherBindingInfo.self, try await json("GET", "publishers/\(Self.seg(signerId))"))
    }

    /// Bind a package signing key to `org` as its publisher, with `passkey`.
    @discardableResult
    public func bindPublisher(
        _ org: String, _ proof: PublisherProof, passkey: any PasskeyProvider
    ) async throws
        -> JSONValue
    {
        try await postConfirmed("orgs/\(Self.seg(org))/publishers", try Self.json(proof), passkey: passkey)
    }

    /// Upgrade every instance of `package` that declares `upgrades: publisher`, as its publisher `org`.
    public func upgradePublished(
        _ org: String, package: String, version: String, migrate: String? = nil, passkey: any PasskeyProvider
    ) async throws -> UpgradeRun {
        var body: [String: JSONValue] = ["version": .string(version)]
        if let migrate { body["migrate"] = .string(migrate) }
        let answer = try await postConfirmed(
            "orgs/\(Self.seg(org))/packages/\(Self.seg(package))/upgrade", .object(body), passkey: passkey)
        return try decode(UpgradeRun.self, CanonicalJSON.data(answer))
    }

    // MARK: - Operator

    /// `GET /ops/apps`. Operator token (``useApiKey(_:)``).
    public func opsApps(page: PageOptions = PageOptions()) async throws -> JSONValue {
        try await get("ops/apps" + (try page.query()))
    }

    /// `GET /ops/orgs`. Operator token.
    public func opsOrgs(page: PageOptions = PageOptions()) async throws -> JSONValue {
        try await get("ops/orgs" + (try page.query()))
    }

    /// Announce when work on images older than `version` ends. Operator token.
    public func setReleaseDeadline(_ version: String, after: Date) async throws {
        let formatter = ISO8601DateFormatter()
        try await post(
            "ops/releases/\(Self.seg(version))/deadline", ["after": .string(formatter.string(from: after))])
    }

    /// Lift a release's deadline. Operator token.
    public func liftReleaseDeadline(_ version: String) async throws {
        try await delete("ops/releases/\(Self.seg(version))/deadline")
    }

    // MARK: - Members, teams and invites

    /// Add a member, or change their role.
    public func setMember(_ org: String, account: String, role: OrgRole) async throws {
        try await post("orgs/\(Self.seg(org))/members", ["account": .string(account), "role": .string(role.rawValue)])
    }

    @discardableResult
    public func removeMember(_ org: String, account: String) async throws -> JSONValue {
        try await delete("orgs/\(Self.seg(org))/members/\(Self.seg(account))")
    }

    /// Set capability bits: for a member, a member of one team, or the organization's default (neither).
    public func setCapabilities(
        _ org: String, _ capabilities: OrgCapabilities, account: String? = nil, team: String? = nil
    ) async throws {
        var body: [String: JSONValue] = ["capabilities": .number(Double(capabilities.rawValue))]
        if let account { body["account"] = .string(account) }
        if let team { body["team"] = .string(team) }
        try await post("orgs/\(Self.seg(org))/capabilities", .object(body))
    }

    /// Create a team; answers its id.
    public func createTeam(_ org: String, name: String, join: TeamJoin, parent: String? = nil) async throws -> String {
        var body: [String: JSONValue] = ["name": .string(name), "join": .string(join.rawValue)]
        if let parent { body["parent"] = .string(parent) }
        return try await post("orgs/\(Self.seg(org))/teams", .object(body))["teamId"]?.stringValue ?? ""
    }

    public func getTeam(_ org: String, _ team: String) async throws -> TeamInfo {
        TeamInfo(json: try await get("orgs/\(Self.seg(org))/teams/\(Self.seg(team))"), org: org)
    }

    /// Rename, change who may join, set the app's metadata, or move the team:
    /// `parent` `.some(nil)` moves it to the top, `nil` leaves it.
    public func updateTeam(
        _ org: String, _ team: String, name: String? = nil, join: TeamJoin? = nil, parent: String?? = nil,
        metadata: JSONValue? = nil
    ) async throws {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = .string(name) }
        if let join { body["join"] = .string(join.rawValue) }
        if let parent { body["parent"] = parent.map { .string($0) } ?? .null }
        if let metadata { body["metadata"] = metadata }
        try await post("orgs/\(Self.seg(org))/teams/\(Self.seg(team))", .object(body))
    }

    /// Delete a team, the teams below it and their apps.
    public func deleteTeam(_ org: String, _ team: String) async throws {
        try await delete("orgs/\(Self.seg(org))/teams/\(Self.seg(team))")
    }

    /// Add a member to a team, or change their row.
    public func setTeamMember(
        _ org: String, _ team: String, account: String, role: TeamRole? = nil, lead: Bool? = nil,
        capabilities: OrgCapabilities? = nil
    ) async throws {
        var body: [String: JSONValue] = ["account": .string(account)]
        if let role { body["role"] = .string(role.rawValue) }
        if let lead { body["lead"] = .bool(lead) }
        if let capabilities { body["capabilities"] = .number(Double(capabilities.rawValue)) }
        try await post("orgs/\(Self.seg(org))/teams/\(Self.seg(team))/members", .object(body))
    }

    public func removeTeamMember(_ org: String, _ team: String, account: String) async throws {
        try await delete("orgs/\(Self.seg(org))/teams/\(Self.seg(team))/members/\(Self.seg(account))")
    }

    /// Mint an invite token (`inv_…`) to `org` with `role`, into `teams`.
    public func invite(
        _ org: String, role: OrgRole = .member, teams: [String] = [], ttlSecs: Int? = nil, uses: Int? = nil
    ) async throws -> String {
        var body: [String: JSONValue] = [
            "role": .string(role.rawValue), "teams": .array(teams.map { .string($0) }),
        ]
        if let ttlSecs { body["ttlSecs"] = .number(Double(ttlSecs)) }
        if let uses { body["uses"] = .number(Double(uses)) }
        let answer = try await post("orgs/\(Self.seg(org))/invites", .object(body))
        guard let token = answer["token"]?.stringValue else { throw AccountError.protocolViolation("no invite token") }
        return token
    }

    /// Redeem an invite token: the signed-in account joins its organization.
    @discardableResult
    public func redeemInvite(_ token: String) async throws -> JSONValue {
        try await post("invites/\(Self.seg(token))/redeem")
    }

    // MARK: - Helpers

    /// One URL path segment, so an id cannot reach another route.
    static func seg(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathSegment) ?? value
    }

    static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValue) ?? value
    }

    /// A key for a call the caller gave none, made once so every retry
    /// shares it: `node:c-` and 16 random bytes in base64url, as the Rust
    /// client mints it (the node keeps a `node:` key 10 minutes).
    static func newIdempotencyKey() -> String {
        "node:c-\(b64url(randomBytes(16)))"
    }

    /// `{"args":…,"idempotencyKey":…,"method":…}` with `argsJSON` as written.
    static func body(method: String, argsJSON: Data, key: String) throws -> Data {
        let args: String
        do {
            args = LiteralJSON.write(try LiteralJSON.parse(argsJSON.isEmpty ? Data("{}".utf8) : argsJSON))
        } catch {
            throw AccountError.invalidInput("argsJSON is not JSON: \(error)")
        }
        return Data(
            "{\"args\":\(args),\"idempotencyKey\":\(CanonicalJSON.quote(key)),\"method\":\(CanonicalJSON.quote(method))}"
                .utf8)
    }

    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try MeroJSON.decode(JSONValue.self, from: try MeroJSON.encode(value))
    }
}

/// A call's bundle: a hash, or a package release. (== mero-js `createApp`'s `bundle`.)
public enum AppSource: Sendable, Equatable {
    /// A bundle hash (a raw upload, development clusters only).
    case bundle(String)
    /// A package release: the latest when `version` is `nil`; `service` names
    /// one service of a multi-service bundle.
    case package(String, version: String? = nil, service: String? = nil)
}

private struct BlobList: Decodable { let blobs: [BlobInfo] }
private struct PackageList: Decodable { let packages: [PackageInfo] }
private struct AppList: Decodable { let apps: [AppInfo] }
private struct PresenceList: Decodable { let present: [PresenceEntry] }

/// Server-sent event frames from a byte stream: `{ id, kind, data }` each,
/// `data` parsed as JSON when it is. (== mero-js `sseFrames`.)
struct SseParser {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [CloudEvent] {
        buffer.append(chunk)
        var out: [CloudEvent] = []
        while let cut = Self.frameEnd(buffer) {
            let frame = String(decoding: buffer[buffer.startIndex..<cut.lowerBound], as: UTF8.self)
            buffer = Data(buffer[cut.upperBound...])
            var id = ""
            var kind = ""
            var data = ""
            for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = line.hasSuffix("\r") ? line.dropLast() : line[...]
                if line.hasPrefix("id:") {
                    id = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("event:") {
                    kind = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                }
            }
            if kind.isEmpty && data.isEmpty { continue }
            let parsed = (try? MeroJSON.decode(JSONValue.self, from: Data(data.utf8))) ?? .string(data)
            out.append(CloudEvent(id: id, kind: kind, data: parsed))
        }
        return out
    }

    private static func frameEnd(_ data: Data) -> Range<Data.Index>? {
        let lf = data.range(of: Data("\n\n".utf8))
        let crlf = data.range(of: Data("\r\n\r\n".utf8))
        switch (lf, crlf) {
        case (let a?, let b?): return a.lowerBound <= b.lowerBound ? a : b
        case (let a?, nil): return a
        case (nil, let b?): return b
        default: return nil
        }
    }
}
