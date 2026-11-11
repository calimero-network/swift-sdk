import Foundation
import MeroAPI
import OpenAPIRuntime

// The methods `CalimeroClient` had before MeroKit's API was generated from
// core's OpenAPI document, each now one call of the facade
// (Api/Generated/Facade.swift) and deprecated in its favour. Each keeps its
// name, its signature and its answer type; the answer is still decoded the
// way the method always read it (`legacy`), so a field the document does not
// name (or names but a node leaves out) reads as before.
extension CalimeroClient {
    // MARK: - Identity

    /// Who may create an account on the cluster (`GET /sign-up`, core
    /// rc.9+); needs no session.
    @available(*, deprecated, message: "use client.deploymentsApi.signUpPublic()")
    public func signUpPolicy() async throws -> SignUpPolicy {
        try await legacy(SignUpPolicy.self) { try await self.deploymentsApi.signUpPublic() }
    }

    /// `GET /auth/me`: the account, its passkeys and its organizations.
    @available(*, deprecated, message: "use client.auth.me()")
    public func me() async throws -> AccountInfo {
        AccountInfo(json: try await legacyValue { try await self.auth.me() })
    }

    /// Remove one of the account's passkeys (not the last), approved with `passkey` (one it has).
    @available(*, deprecated, message: "use client.auth.passkeyRemove(cred:passkey:)")
    public func removePasskey(_ credentialId: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.auth.passkeyRemove(cred: credentialId, passkey: passkey) }
    }

    /// Name one of the account's passkeys; `""` clears the name.
    @available(*, deprecated, message: "use client.auth.passkeyLabel(cred:label:)")
    public func labelPasskey(_ credentialId: String, label: String) async throws {
        _ = try await answer { try await self.auth.passkeyLabel(cred: credentialId, label: label) }
    }

    /// What this account uses, with the cluster's quotas.
    @available(*, deprecated, message: "use client.auth.usage()")
    public func usage() async throws -> JSONValue {
        try await legacyValue { try await self.auth.usage() }
    }

    /// The node's attestation document, unverified: for display only. Every
    /// request this client sends is sealed to a key it verified itself first.
    @available(*, deprecated, message: "use client.publicApi.attestation(nonce:)")
    public func attestation() async throws -> AttestationDoc {
        let nonce = Hex.encode(randomBytes(32))
        return try await legacy(AttestationDoc.self) { try await self.publicApi.attestation(nonce: nonce) }
    }

    /// The account's API keys (never the keys themselves).
    @available(*, deprecated, message: "use client.auth.apikeyList()")
    public func listApiKeys() async throws -> [JSONValue] {
        try await legacyValue { try await self.auth.apikeyList() }["keys"]?.arrayValue ?? []
    }

    /// Revoke one of the account's API keys, approved with its `passkey`
    /// (`412 CONFIRM_REQUIRED`, core rc.9+).
    @available(*, deprecated, message: "use client.auth.apikeyRevoke(key:passkey:)")
    public func revokeApiKey(_ keyId: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.auth.apikeyRevoke(key: keyId, passkey: passkey) }
    }

    /// Create an API key for an agent or server, approved with the account's
    /// `passkey` (`412 CONFIRM_REQUIRED`); needs a passkey session (an API
    /// key is refused `403`). The key is returned once.
    ///
    /// `upgrades` (core rc.10+) makes an upgrade key, for CI: it upgrades
    /// that one app to signed releases of its package (default: the one the
    /// app runs, by that package's pinned signer) with
    /// ``upgradeApp(_:version:package:service:bundle:migrate:passkey:)`` and
    /// no passkey, and every other request with it is refused `403
    /// UPGRADE_KEY_ONLY`. It takes no other scope field.
    @available(*, deprecated, message: "use client.auth.apikeyCreate")
    public func createApiKey(
        label: String? = nil, apps: [String]? = nil, methods: [String]? = nil, readOnly: Bool? = nil,
        allowConfirm: Bool? = nil, ttlSecs: Int? = nil, upgrades: UpgradeKeyScope? = nil,
        passkey: any PasskeyProvider
    ) async throws -> (keyId: String, key: String) {
        let scope = upgrades.map {
            Operations.ApikeyCreate.Input.Body.JsonPayload.UpgradesPayload(app: $0.app, package: $0.package)
        }
        let answer = try await legacyValue {
            try await self.auth.apikeyCreate(
                label: label, apps: apps, methods: methods, readOnly: readOnly, allowConfirm: allowConfirm,
                ttlSecs: ttlSecs.map { Int64($0) }, upgrades: scope, passkey: passkey)
        }
        return (answer["keyId"]?.stringValue ?? "", answer["key"]?.stringValue ?? "")
    }

    // MARK: - Bundles and blobs

    /// Upload a raw WASM bundle (development clusters only); answers its hash.
    @available(*, deprecated, message: "use client.packagesApi.bundlePut(body:)")
    public func uploadBundle(_ wasm: Data) async throws -> String {
        try await legacyValue { try await self.packagesApi.bundlePut(body: wasm) }["hash"]?.stringValue ?? ""
    }

    /// One of `app`'s blobs, by id (base58 or hex).
    @available(*, deprecated, message: "use client.apps.blobDownload(app:id:)")
    public func downloadBlob(_ app: String, _ id: String) async throws -> Data {
        try await blobContent(app, id).data
    }

    /// Download a component app's blob with a grant one of its runs handed
    /// out (`BlobRef::grant`, up to 24 h). No session needed: the grant is
    /// the permission. A bad or expired grant answers ``NotFound``, as a
    /// missing blob.
    @available(*, deprecated, message: "use client.apps.blobDownload(app:id:grant:)")
    public func downloadBlobGranted(_ app: String, _ id: String, grant: String) async throws -> Data {
        try await blobContent(app, id, grant: grant).data
    }

    /// Delete one of `app`'s blobs (its owner, or an admin of its organization).
    @available(*, deprecated, message: "use client.apps.blobDelete(app:id:)")
    public func deleteBlob(_ app: String, _ id: String) async throws {
        _ = try await answer { try await self.apps.blobDelete(app: app, id: id) }
    }

    // MARK: - Packages

    /// Install a signed `.mpk` package file (development clusters only).
    @available(*, deprecated, message: "use client.packagesApi.upload(body:)")
    public func uploadPackage(_ mpk: Data) async throws -> PackageInstalled {
        try await legacy(PackageInstalled.self) { try await self.packagesApi.upload(body: mpk) }
    }

    /// Install `package@version` from the cluster's registry.
    @available(*, deprecated, message: "use client.packagesApi.install(package:version:)")
    public func installPackage(_ package: String, version: String) async throws -> PackageInstalled {
        try await legacy(PackageInstalled.self) {
            try await self.packagesApi.install(package: package, version: version)
        }
    }

    /// Installed packages and their versions.
    @available(*, deprecated, message: "use client.packagesApi.list()")
    public func packages() async throws -> [PackageInfo] {
        try await legacy(PackageList.self) { try await self.packagesApi.list() }.packages
    }

    /// One installed package and its versions.
    @available(*, deprecated, message: "use client.packagesApi.get(package:)")
    public func package(_ package: String) async throws -> PackageInfo {
        try await legacy(PackageInfo.self) { try await self.packagesApi.get(package: package) }
    }

    /// Uninstall one version, or the whole package. Refused while an app runs it.
    @discardableResult
    @available(*, deprecated, message: "use client.packagesApi.uninstall or client.packagesApi.versionUninstall")
    public func uninstallPackage(_ package: String, version: String? = nil) async throws -> JSONValue {
        if let version {
            return try await legacyValue {
                try await self.packagesApi.versionUninstall(package: package, version: version)
            }
        }
        return try await legacyValue { try await self.packagesApi.uninstall(package: package) }
    }

    // MARK: - App instances

    /// Apps this caller reaches, optionally only those of one package or bundle.
    @available(*, deprecated, message: "use client.apps.list(package:bundle:)")
    public func listApps(package: String? = nil, bundle: String? = nil) async throws -> [AppInfo] {
        try await legacy(AppList.self) { try await self.apps.list(package: package, bundle: bundle) }.apps
    }

    /// The app's record: `name`, `owner`, `org`, `access`, `metadata`, `bundle`, ….
    @available(*, deprecated, message: "use client.apps.get(app:)")
    public func getApp(_ app: String) async throws -> JSONValue {
        try await legacyValue { try await self.apps.get(app: app) }
    }

    /// Delete an app instance (its owner, or an admin of its organization).
    @available(*, deprecated, message: "use client.apps.delete(app:)")
    public func deleteApp(_ app: String) async throws {
        _ = try await answer { try await self.apps.delete(app: app) }
    }

    /// Who may reach the app.
    @available(*, deprecated, message: "use client.apps.access(app:access:)")
    public func setAccess(_ app: String, _ access: AppAccess) async throws {
        let access = access.generated
        _ = try await answer { try await self.apps.access(app: app, access: access) }
    }

    /// Set the app instance's metadata; at most 16 KiB.
    @available(*, deprecated, message: "use client.apps.metadata(app:metadata:)")
    public func setAppMetadata(_ app: String, _ metadata: JSONValue) async throws {
        let metadata = try OpenAPIValueContainer(metadata)
        _ = try await answer { try await self.apps.metadata(app: app, metadata: metadata) }
    }

    /// A component app's xcalls: how many messages wait in its outbox, and
    /// the dead letters (never delivered), newest last. Its owner's or an org
    /// admin's (`403` to anyone else); `409 NOT_SUPPORTED` for an app on the
    /// wasmer runtime, whose xcalls are follow-ups.
    @available(*, deprecated, message: "use client.apps.xcalls(app:)")
    public func appXcalls(_ app: String) async throws -> AppXcalls {
        try await legacy(AppXcalls.self) { try await self.apps.xcalls(app: app) }
    }

    /// What the app's storage holds: `{ keys, bytes, blobs, blobBytes }`.
    @available(*, deprecated, message: "use client.apps.storage(app:)")
    public func appStorage(_ app: String) async throws -> JSONValue {
        try await legacyValue { try await self.apps.storage(app: app) }
    }

    /// The ABI the app's bundle embeds: `{ bundle, abi }`.
    @available(*, deprecated, message: "use client.apps.abi(app:)")
    public func appAbi(_ app: String) async throws -> JSONValue {
        try await legacyValue { try await self.apps.abi(app: app) }
    }

    /// Hand the app to another account. The owner approves with `passkey`.
    @available(*, deprecated, message: "use client.apps.transfer(app:to:passkey:)")
    public func transferApp(_ app: String, to: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.apps.transfer(app: app, to: to, passkey: passkey) }
    }

    /// Move an app to another release of its package (`version`), another
    /// package, or a bundle hash, running its migration. Where the node asks
    /// for an approval (`412 CONFIRM_REQUIRED`), `passkey` gives it. With an
    /// upgrade key (``createApiKey(label:apps:methods:readOnly:allowConfirm:ttlSecs:upgrades:passkey:)``
    /// `upgrades`) pass no passkey and a `version` of the key's package.
    @discardableResult
    @available(*, deprecated, message: "use client.apps.upgrade(app:bundle:package:version:service:migrate:passkey:)")
    public func upgradeApp(
        _ app: String, version: String? = nil, package: String? = nil, service: String? = nil, bundle: String? = nil,
        migrate: String? = nil, passkey: (any PasskeyProvider)? = nil
    ) async throws -> JSONValue {
        try await legacyValue {
            try await self.apps.upgrade(
                app: app, bundle: bundle, package: package, version: version, service: service, migrate: migrate,
                passkey: passkey)
        }
    }

    /// Create an app instance from a bundle hash, or from a package release
    /// (installed from the registry first if the cluster lacks it). With a
    /// `deployment`, the instance runs the release that deployment offers for
    /// the package (`version`, if given, must be it) and records the
    /// deployment; no install, no deployer grant. A package or version it does
    /// not offer answers `400 NOT_OFFERED`, several offered releases with no
    /// `version` `400 VERSION_REQUIRED`, and an unknown `service` `400
    /// NO_SUCH_SERVICE`. A page opened through `/d/{deployment}/` finds its
    /// deployment with ``pageDeployment(_:)``. Answers its app id.
    @available(*, deprecated, message: "use client.apps.create")
    public func createApp(
        _ name: String, bundle: AppSource, org: String? = nil, access: AppAccess? = nil,
        confirmMethods: [String]? = nil, initArgs: JSONValue? = nil
    ) async throws -> String {
        var hash: String?
        var release: (package: String, version: String?)?
        var service: String?
        var deployment: String?
        switch bundle {
        case .bundle(let value): hash = value
        case .package(let id, let v, let s, let d):
            release = (id, v)
            service = s
            deployment = d
        }
        // Copies the @Sendable request below may capture.
        let bundleHash = hash
        let package = release?.package
        let version = release?.version
        let serviceName = service
        let deploymentId = deployment
        let answer: JSONValue
        if let confirmMethods {
            // `confirmMethods` is not in the document's `POST /apps` body: sent as written.
            var body: [String: JSONValue] = ["name": .string(name)]
            for (key, value) in [
                ("bundle", bundleHash), ("package", package), ("version", version), ("service", serviceName),
                ("deployment", deploymentId), ("org", org),
            ] {
                if let value { body[key] = .string(value) }
            }
            if let access { body["access"] = access.json }
            body["confirmMethods"] = .array(confirmMethods.map { .string($0) })
            if let initArgs { body["initArgs"] = initArgs }
            answer = try await post("apps", .object(body))
        } else {
            let access = access?.generated
            let initArgs = try initArgs.map { try OpenAPIValueContainer($0) }
            answer = try await legacyValue {
                try await self.apps.create(
                    name: name, bundle: bundleHash, package: package, version: version, service: serviceName,
                    org: org, access: access, initArgs: initArgs, deployment: deploymentId)
            }
        }
        guard let appId = answer["appId"]?.stringValue else {
            throw AccountError.protocolViolation("the node created no app")
        }
        return appId
    }

    // MARK: - Presence

    /// Publish this device's presence in `app`: `state` (at most 4 KiB) or
    /// `nil` to retract it. Send the same `seq` and state again as a
    /// heartbeat: an entry not refreshed within 7 s is gone.
    @available(*, deprecated, message: "use client.apps.presencePublish(app:seq:state:)")
    public func publishPresence(_ app: String, seq: Int, state: Data?) async throws {
        // `nil` retracts it: an explicit `state: null`, as before.
        let state: String?? = .some(state.map { Hex.encode($0) })
        _ = try await answer { try await self.apps.presencePublish(app: app, seq: Int64(seq), state: state) }
    }

    /// Who is present in `app` now.
    @available(*, deprecated, message: "use client.apps.presenceGet(app:)")
    public func presence(_ app: String) async throws -> [PresenceEntry] {
        try await legacy(PresenceList.self) { try await self.apps.presenceGet(app: app) }.present
    }

    // MARK: - Aliases

    /// Name an app for this account.
    @available(*, deprecated, message: "use client.auth.aliasSet(alias:app:)")
    public func setAlias(_ alias: String, app: String) async throws {
        _ = try await answer { try await self.auth.aliasSet(alias: alias, app: app) }
    }

    /// This account's aliases, alias → app id.
    @available(*, deprecated, message: "use client.auth.aliasList()")
    public func aliases() async throws -> [String: String] {
        (try await legacyValue { try await self.auth.aliasList() }["aliases"]?.objectValue ?? [:])
            .compactMapValues(\.stringValue)
    }

    /// The app an alias names.
    @available(*, deprecated, message: "use client.auth.aliasGet(alias:)")
    public func alias(_ alias: String) async throws -> String {
        try await legacyValue { try await self.auth.aliasGet(alias: alias) }["appId"]?.stringValue ?? ""
    }

    @available(*, deprecated, message: "use client.auth.aliasDelete(alias:)")
    public func deleteAlias(_ alias: String) async throws {
        _ = try await answer { try await self.auth.aliasDelete(alias: alias) }
    }

    // MARK: - Organizations

    /// Create an organization; answers its id. `recoveryKey` (core rc.9+,
    /// ``RecoverySeed/publicKey``) lets whoever holds its seed recover the
    /// organization if its owner loses every passkey; keep the seed offline
    /// (``RecoverySeed/text``).
    @available(*, deprecated, message: "use client.orgs.create(name:recoveryKey:)")
    public func createOrg(_ name: String, recoveryKey: String? = nil) async throws -> String {
        try await legacyValue { try await self.orgs.create(name: name, recoveryKey: recoveryKey) }["orgId"]?
            .stringValue ?? ""
    }

    /// Cancel the recovery under way: the organization's owner, approved with `passkey` (core rc.9+).
    @available(*, deprecated, message: "use client.orgs.recoveryCancel(org:passkey:)")
    public func cancelRecovery(_ org: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.orgs.recoveryCancel(org: org, passkey: passkey) }
    }

    /// Finish a recovery this account started, once its delay passed
    /// (``RecoveryNotReady`` before, with `readyAt`), approved with this
    /// account's `passkey` (core rc.9+). The account becomes the owner; the
    /// previous owner leaves the organization.
    @discardableResult
    @available(*, deprecated, message: "use client.orgs.recoveryFinish(org:passkey:)")
    public func finishRecovery(_ org: String, passkey: any PasskeyProvider) async throws -> RecoveryFinished {
        let answer = try await legacyValue { try await self.orgs.recoveryFinish(org: org, passkey: passkey) }
        return RecoveryFinished(
            org: answer["org"]?.stringValue ?? org,
            previousOwners: (answer["previousOwners"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// The organization, with the teams this caller reaches or manages.
    @available(*, deprecated, message: "use client.orgs.get(org:)")
    public func getOrg(_ org: String) async throws -> OrgInfo {
        OrgInfo(json: try await legacyValue { try await self.orgs.get(org: org) })
    }

    /// Delete an organization with its teams, invites and apps (its owner, with `passkey`).
    @available(*, deprecated, message: "use client.orgs.delete(org:passkey:)")
    public func deleteOrg(_ org: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.orgs.delete(org: org, passkey: passkey) }
    }

    /// Set the organization's metadata; at most 16 KiB.
    @available(*, deprecated, message: "use client.orgs.metadata(org:metadata:)")
    public func setOrgMetadata(_ org: String, _ metadata: JSONValue) async throws {
        let metadata = try OpenAPIValueContainer(metadata)
        _ = try await answer { try await self.orgs.metadata(org: org, metadata: metadata) }
    }

    /// Set a member's metadata (theirs, or an admin's); `.null` clears it.
    @available(*, deprecated, message: "use client.orgs.memberMetadata(org:account:metadata:)")
    public func setMemberMetadata(_ org: String, account: String, _ metadata: JSONValue) async throws {
        let metadata = try OpenAPIValueContainer(metadata)
        _ = try await answer { try await self.orgs.memberMetadata(org: org, account: account, metadata: metadata) }
    }

    /// Upgrade every app of `org` that runs `target.package`, approved with `passkey`.
    @available(*, deprecated, message: "use client.orgs.upgrade(org:package:version:team:cascade:migrate:passkey:)")
    public func upgradeOrg(
        _ org: String, _ target: OrgUpgradeTarget, passkey: any PasskeyProvider
    ) async throws
        -> UpgradeRun
    {
        try await legacy(UpgradeRun.self) {
            try await self.orgs.upgrade(
                org: org, package: target.package, version: target.version, team: target.team,
                cascade: target.cascade, migrate: target.migrate, passkey: passkey)
        }
    }

    /// An organization-wide upgrade run.
    @available(*, deprecated, message: "use client.orgs.upgradeStatus(org:run:)")
    public func upgradeRun(_ org: String, _ run: String) async throws -> UpgradeRun {
        try await legacy(UpgradeRun.self) { try await self.orgs.upgradeStatus(org: org, run: run) }
    }

    /// Run the apps that failed in `run` again, as a new run, approved with `passkey`.
    @available(*, deprecated, message: "use client.orgs.upgradeRetry(org:run:passkey:operatorSigner:)")
    public func retryUpgradeRun(_ org: String, _ run: String, passkey: any PasskeyProvider) async throws -> UpgradeRun {
        try await legacy(UpgradeRun.self) { try await self.orgs.upgradeRetry(org: org, run: run, passkey: passkey) }
    }

    /// Approve a mero-tee release for `org`'s apps, or this account's own
    /// (`org` `nil`); `approved: false` withdraws it. Refused to a session
    /// opened on an app's frontend: ask with ``requestConsent(_:)`` instead.
    @discardableResult
    @available(*, deprecated, message: "use client.orgs.releaseApproval or client.auth.releaseApproval")
    public func approveRelease(
        _ org: String?, version: String, passkey: any PasskeyProvider, approved: Bool = true
    )
        async throws -> JSONValue
    {
        if let org {
            return try await legacyValue {
                try await self.orgs.releaseApproval(org: org, version: version, approved: approved, passkey: passkey)
            }
        }
        return try await legacyValue {
            try await self.auth.releaseApproval(version: version, approved: approved, passkey: passkey)
        }
    }

    /// Approve the URL prefixes apps from `package`'s publisher may call out
    /// to; `prefixes` `nil` approves every prefix the package's latest
    /// release declares; `replace` sets exactly `prefixes`.
    @discardableResult
    @available(*, deprecated, message: "use client.orgs.outboundApproval or client.auth.outboundApproval")
    public func approveOutbound(
        _ org: String?, package: String, passkey: any PasskeyProvider, prefixes: [String]? = nil, replace: Bool = false
    ) async throws -> JSONValue {
        let selection: Components.Schemas.OutboundSelection = try Self.converted(
            json: prefixes.map { .array($0.map { .string($0) }) } ?? "manifest")
        if let org {
            return try await legacyValue {
                try await self.orgs.outboundApproval(
                    org: org, package: package, prefixes: selection, replace: replace, passkey: passkey)
            }
        }
        return try await legacyValue {
            try await self.auth.outboundApproval(
                package: package, prefixes: selection, replace: replace, passkey: passkey)
        }
    }

    // MARK: - Approvals

    /// One page of the report of a scope's apps.
    @available(*, deprecated, message: "use client.orgs.apps(org:after:limit:) or client.auth.apps(after:limit:)")
    public func appsReport(_ org: String?, page: PageOptions = PageOptions()) async throws -> AppsReport {
        _ = try page.query()  // refuses a `limit` outside 1 to 100 before sending
        if let org {
            return try await legacy(AppsReport.self) {
                try await self.orgs.apps(org: org, after: page.after, limit: page.limit.map { Int64($0) })
            }
        }
        return try await legacy(AppsReport.self) {
            try await self.auth.apps(after: page.after, limit: page.limit.map { Int64($0) })
        }
    }

    /// `GET /releases`: the cluster's governance and every release deadline.
    @available(*, deprecated, message: "use client.publicApi.releasesPublic()")
    public func releaseRules() async throws -> ReleaseRules {
        try await legacy(ReleaseRules.self) { try await self.publicApi.releasesPublic() }
    }

    /// The decision on a consent request.
    @available(*, deprecated, message: "use client.consent.pageResult(request:)")
    public func consentResult(_ requestId: String) async throws -> ConsentResult {
        try await legacy(ConsentResult.self) { try await self.consent.pageResult(request: requestId) }
    }

    /// `GET /publishers/{signerId}`.
    @available(*, deprecated, message: "use client.publicApi.publisherBinding(signer:)")
    public func publisherBinding(_ signerId: String) async throws -> PublisherBindingInfo {
        try await legacy(PublisherBindingInfo.self) { try await self.publicApi.publisherBinding(signer: signerId) }
    }

    /// Bind a package signing key to `org` as its publisher, with `passkey`.
    @discardableResult
    @available(*, deprecated, message: "use client.orgs.publisher(org:signerId:publicKey:signature:passkey:)")
    public func bindPublisher(
        _ org: String, _ proof: PublisherProof, passkey: any PasskeyProvider
    ) async throws
        -> JSONValue
    {
        try await legacyValue {
            try await self.orgs.publisher(
                org: org, signerId: proof.signerId, publicKey: proof.publicKey, signature: proof.signature,
                passkey: passkey)
        }
    }

    /// Upgrade every instance of `package` that declares `upgrades: publisher`, as its publisher `org`.
    @available(*, deprecated, message: "use client.orgs.publisherUpgrade(org:package:version:migrate:passkey:)")
    public func upgradePublished(
        _ org: String, package: String, version: String, migrate: String? = nil, passkey: any PasskeyProvider
    ) async throws -> UpgradeRun {
        try await legacy(UpgradeRun.self) {
            try await self.orgs.publisherUpgrade(
                org: org, package: package, version: version, migrate: migrate, passkey: passkey)
        }
    }

    // MARK: - Operator

    /// `GET /ops/apps`. Operator token (``useApiKey(_:)``).
    @available(*, deprecated, message: "use client.ops.apps(after:limit:)")
    public func opsApps(page: PageOptions = PageOptions()) async throws -> JSONValue {
        _ = try page.query()
        return try await legacyValue { try await self.ops.apps(after: page.after, limit: page.limit.map { Int64($0) }) }
    }

    /// `GET /ops/orgs`. Operator token.
    @available(*, deprecated, message: "use client.ops.orgs(after:limit:)")
    public func opsOrgs(page: PageOptions = PageOptions()) async throws -> JSONValue {
        _ = try page.query()
        return try await legacyValue { try await self.ops.orgs(after: page.after, limit: page.limit.map { Int64($0) }) }
    }

    /// Announce when work on images older than `version` ends. Operator token.
    @available(*, deprecated, message: "use client.ops.releaseDeadline(version:after:operatorSigner:)")
    public func setReleaseDeadline(_ version: String, after: Date) async throws {
        let after = ISO8601DateFormatter().string(from: after)
        _ = try await answer { try await self.ops.releaseDeadline(version: version, after: after) }
    }

    /// Lift a release's deadline. Operator token.
    @available(*, deprecated, message: "use client.ops.releaseDeadlineLift(version:operatorSigner:)")
    public func liftReleaseDeadline(_ version: String) async throws {
        _ = try await answer { try await self.ops.releaseDeadlineLift(version: version) }
    }

    // MARK: - Members, teams and invites

    /// Add a member, or change their role, approved with the caller's `passkey`.
    @available(*, deprecated, message: "use client.orgs.setMember(org:account:role:passkey:)")
    public func setMember(
        _ org: String, account: String, role: OrgRole, passkey: any PasskeyProvider
    ) async throws {
        let role: Components.Schemas.OrgRole = try Self.converted(role)
        _ = try await answer { try await self.orgs.setMember(org: org, account: account, role: role, passkey: passkey) }
    }

    /// Remove a member, or leave (`account` the caller's own), approved with the caller's `passkey`.
    @discardableResult
    @available(*, deprecated, message: "use client.orgs.removeMember(org:account:passkey:)")
    public func removeMember(_ org: String, account: String, passkey: any PasskeyProvider) async throws -> JSONValue {
        try await legacyValue { try await self.orgs.removeMember(org: org, account: account, passkey: passkey) }
    }

    /// Set capability bits: for a member, a member of one team, or the
    /// organization's default (neither). Approved with the caller's `passkey`.
    @available(*, deprecated, message: "use client.orgs.capabilities(org:account:team:capabilities:passkey:)")
    public func setCapabilities(
        _ org: String, _ capabilities: OrgCapabilities, passkey: any PasskeyProvider, account: String? = nil,
        team: String? = nil
    ) async throws {
        _ = try await answer {
            try await self.orgs.capabilities(
                org: org, account: account, team: team, capabilities: Int64(capabilities.rawValue), passkey: passkey)
        }
    }

    /// Create a team; answers its id.
    @available(*, deprecated, message: "use client.orgs.teamCreate(org:name:parent:join:)")
    public func createTeam(_ org: String, name: String, join: TeamJoin, parent: String? = nil) async throws -> String {
        let join: Components.Schemas.TeamJoin = try Self.converted(join)
        return try await legacyValue {
            try await self.orgs.teamCreate(org: org, name: name, parent: parent, join: join)
        }["teamId"]?.stringValue ?? ""
    }

    @available(*, deprecated, message: "use client.orgs.teamGet(org:team:)")
    public func getTeam(_ org: String, _ team: String) async throws -> TeamInfo {
        TeamInfo(json: try await legacyValue { try await self.orgs.teamGet(org: org, team: team) }, org: org)
    }

    /// Delete a team, the teams below it and their apps.
    @available(*, deprecated, message: "use client.orgs.teamDelete(org:team:passkey:)")
    public func deleteTeam(_ org: String, _ team: String) async throws {
        _ = try await answer { try await self.orgs.teamDelete(org: org, team: team) }
    }

    /// Add a member to a team, or change their row, approved with the caller's `passkey`.
    @available(*, deprecated, message: "use client.orgs.teamSetMember")
    public func setTeamMember(
        _ org: String, _ team: String, account: String, passkey: any PasskeyProvider, role: TeamRole? = nil,
        lead: Bool? = nil, capabilities: OrgCapabilities? = nil
    ) async throws {
        let role: Components.Schemas.TeamRole? = try role.map { try Self.converted($0) }
        _ = try await answer {
            try await self.orgs.teamSetMember(
                org: org, team: team, account: account, lead: lead, role: role,
                capabilities: capabilities.map { Int64($0.rawValue) },
                passkey: passkey)
        }
    }

    /// Remove a member from a team, approved with the caller's `passkey`.
    @available(*, deprecated, message: "use client.orgs.teamRemoveMember(org:team:account:passkey:)")
    public func removeTeamMember(
        _ org: String, _ team: String, account: String, passkey: any PasskeyProvider
    ) async throws {
        _ = try await answer {
            try await self.orgs.teamRemoveMember(org: org, team: team, account: account, passkey: passkey)
        }
    }

    /// Mint an invite token (`inv_…`) to `org` with `role`, into `teams`,
    /// approved with the caller's `passkey`. ``redeemInvite(_:)`` takes it
    /// (no approval there).
    @available(*, deprecated, message: "use client.orgs.inviteCreate(org:role:teams:ttlSecs:uses:allApps:passkey:)")
    public func invite(
        _ org: String, role: OrgRole = .member, passkey: any PasskeyProvider, teams: [String] = [],
        ttlSecs: Int? = nil, uses: Int? = nil
    ) async throws -> String {
        let role: Components.Schemas.OrgRole = try Self.converted(role)
        let answer = try await legacyValue {
            try await self.orgs.inviteCreate(
                org: org, role: role, teams: teams, ttlSecs: ttlSecs.map { Int64($0) }, uses: uses.map { Int64($0) },
                passkey: passkey)
        }
        guard let token = answer["token"]?.stringValue else { throw AccountError.protocolViolation("no invite token") }
        return token
    }

    /// Redeem an invite token: the signed-in account joins its organization.
    @discardableResult
    @available(*, deprecated, message: "use client.orgs.inviteRedeem(token:)")
    public func redeemInvite(_ token: String) async throws -> JSONValue {
        try await legacyValue { try await self.orgs.inviteRedeem(token: token) }
    }

    // MARK: - Package origins

    /// The web origins `package`'s managers registered (core rc.9+) so a
    /// frontend they host themselves signs people in with passkeys: a session
    /// opened on one is bound to the package. ``NotFound`` for an unknown
    /// package; `403` to anyone not managing it. (== mero-js `packageOrigins.list`.)
    @available(*, deprecated, message: "use client.packagesApi.originsList(package:)")
    public func packageOrigins(_ package: String) async throws -> [PackageOrigin] {
        try await legacy(PackageOriginList.self) { try await self.packagesApi.originsList(package: package) }.origins
    }

    /// Register `origin` (`scheme://host[:port]`) for `package`, approved
    /// with `passkey` (`412 CONFIRM_REQUIRED` over `__add_origin`). `rpId`
    /// defaults to the node's choice for the origin (its host). Refusals:
    /// ``BadOrigin`` (`BAD_ORIGIN`, `BAD_RP_ID`), ``OriginTaken``,
    /// ``QuotaExceeded``. (== mero-js `packageOrigins.add`.)
    @discardableResult
    @available(*, deprecated, message: "use client.packagesApi.originsAdd(package:origin:rpId:served:passkey:)")
    public func addPackageOrigin(
        _ package: String, origin: String, passkey: any PasskeyProvider, rpId: String? = nil
    ) async throws -> PackageOrigin {
        try await legacy(PackageOrigin.self) {
            try await self.packagesApi.originsAdd(package: package, origin: origin, rpId: rpId, passkey: passkey)
        }
    }

    /// Remove `origin` from `package`, approved with `passkey`
    /// (`__remove_origin`). Sessions opened there stop working (`401`).
    /// ``NotFound`` if it was not registered. (== mero-js `packageOrigins.remove`.)
    @available(*, deprecated, message: "use client.packagesApi.originsRemove(package:origin:passkey:)")
    public func removePackageOrigin(_ package: String, origin: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer {
            try await self.packagesApi.originsRemove(package: package, origin: origin, passkey: passkey)
        }
    }

    // MARK: - Deployers

    /// Let an account or organization install apps where the cluster's
    /// deployments are `granted`, until `until` (absent: the grant does not
    /// end). The cluster's owner grants it, approved with `passkey`, where
    /// governance says `deployers: owner`; elsewhere the operator grants with
    /// its key, and this is refused `403`.
    @discardableResult
    @available(*, deprecated, message: "use client.deploymentsApi.deployerGrant(deployer:until:passkey:)")
    public func grantDeployer(
        _ deployer: Deployer, passkey: any PasskeyProvider, until: Date? = nil
    ) async throws -> JSONValue {
        let converted: Components.Schemas.Deployer = try Self.converted(json: deployer.json)
        let until = until.map { ISO8601DateFormatter().string(from: $0) }
        return try await legacyValue {
            try await self.deploymentsApi.deployerGrant(deployer: converted, until: until, passkey: passkey)
        }
    }

    /// Who may install apps on the cluster: its deployments rule, who grants
    /// deployers, its owner and every grant. For the cluster's owner, or the
    /// operator (its token, ``useApiKey(_:)``).
    @available(*, deprecated, message: "use client.deploymentsApi.deployerList()")
    public func deployers() async throws -> DeployersInfo {
        try await legacy(DeployersInfo.self) { try await self.deploymentsApi.deployerList() }
    }

    /// End a deployer's grant, as the cluster's owner, approved with
    /// `passkey`. Apps it installed, and the apps running them, stay.
    @available(*, deprecated, message: "use client.deploymentsApi.deployerRevoke(key:passkey:)")
    public func revokeDeployer(_ deployer: Deployer, passkey: any PasskeyProvider) async throws {
        let key = deployer.key
        _ = try await answer { try await self.deploymentsApi.deployerRevoke(key: key, passkey: passkey) }
    }

    /// ``revokeDeployer(_:passkey:)`` by its key, `account:{id}` or `org:{id}`.
    @available(*, deprecated, message: "use client.deploymentsApi.deployerRevoke(key:passkey:)")
    public func revokeDeployer(key: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.deploymentsApi.deployerRevoke(key: key, passkey: passkey) }
    }

    // MARK: - Deployments

    /// Create a deployment: `owner`'s (the caller's own account, or an
    /// organization where it holds `MANAGE_APPLICATION` org-wide) list of the
    /// apps it offers, named `name` (1 to 64 characters, one line) for
    /// customers. Approved with `passkey`; where deployments are `granted`
    /// the caller needs a deployer grant. Answers the deployment's id.
    @available(*, deprecated, message: "use client.deploymentsApi.create(name:owner:passkey:)")
    public func createDeployment(_ name: String, owner: Deployer, passkey: any PasskeyProvider) async throws -> String {
        let owner: Components.Schemas.Deployer = try Self.converted(json: owner.json)
        let answer = try await legacyValue {
            try await self.deploymentsApi.create(name: name, owner: owner, passkey: passkey)
        }
        guard let id = answer["id"]?.stringValue else { throw AccountError.protocolViolation("no deployment id") }
        return id
    }

    /// The deployments the caller manages: its account's, and its
    /// organizations' where it holds `MANAGE_APPLICATION`.
    @available(*, deprecated, message: "use client.deploymentsApi.list()")
    public func deployments() async throws -> [DeploymentInfo] {
        try await legacy(DeploymentList.self) { try await self.deploymentsApi.list() }.deployments
    }

    /// A deployment as anyone may read it: its name, its owner's kind and
    /// name, and the apps it offers. Public.
    @available(*, deprecated, message: "use client.deploymentsApi.get(id:)")
    public func deployment(_ id: String) async throws -> PublicDeployment {
        try await legacy(PublicDeployment.self) { try await self.deploymentsApi.get(id: id) }
    }

    /// Delete a deployment that offers nothing and has no instances, approved with `passkey`.
    @available(*, deprecated, message: "use client.deploymentsApi.delete(id:passkey:)")
    public func deleteDeployment(_ id: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.deploymentsApi.delete(id: id, passkey: passkey) }
    }

    /// Offer `package@version` (installed, and seen by the caller) as `app`
    /// (1 to 64 letters, digits, `.`, `_`, `-`) in deployment `id`, or move
    /// an offered app to another release of its package. Approved with `passkey`.
    @discardableResult
    @available(*, deprecated, message: "use client.deploymentsApi.offer(id:app:package:version:passkey:)")
    public func offerApp(
        _ id: String, app: String, package: String, version: String, passkey: any PasskeyProvider
    ) async throws -> JSONValue {
        try await legacyValue {
            try await self.deploymentsApi.offer(
                id: id, app: app, package: package, version: version, passkey: passkey)
        }
    }

    /// Withdraw `app` from deployment `id`, approved with `passkey`; refused
    /// while an instance created from the deployment still runs it.
    @available(*, deprecated, message: "use client.deploymentsApi.withdraw(id:app:passkey:)")
    public func withdrawApp(_ id: String, app: String, passkey: any PasskeyProvider) async throws {
        _ = try await answer { try await self.deploymentsApi.withdraw(id: id, app: app, passkey: passkey) }
    }

    /// The organizations with instances created from deployment `id`, for
    /// its managers: each one's id, name, instance count, apps and releases,
    /// and first instance. Never members, teams or app data.
    @available(*, deprecated, message: "use client.deploymentsApi.orgs(id:)")
    public func deploymentOrgs(_ id: String) async throws -> DeploymentOrgs {
        try await legacy(DeploymentOrgs.self) { try await self.deploymentsApi.orgs(id: id) }
    }
}
