import Foundation
import MeroKit

/// ``MeroAppBackend`` over a signed-in ``CalimeroClient``: Calimero 1.0's
/// orgs, teams and app instances under the app layer's names.
/// (== Kotlin `com.calimero.mero.compose.CalimeroAppBackend`.)
///
/// | Backend call | Node route |
/// | --- | --- |
/// | ``listNamespaces()`` | `GET /auth/me` (orgs), `GET /orgs/{org}` (metadata, members), `GET /apps?package=` |
/// | ``listSubgroups(namespaceId:)`` | `GET /orgs/{org}` (teams), `GET /orgs/{org}/teams/{team}` (apps) |
/// | ``listContexts(groupId:)`` | a team's apps; an org's apps in no team (`GET /apps`) |
/// | ``isMember(contextId:)`` / ``joinContext(contextId:)`` | `GET /apps/{app}` (reachable or `NotFound`) |
/// | ``foundNamespace(name:)`` | `POST /orgs`, `POST /orgs/{org}/metadata {package, name}` |
/// | ``createSubgroup(namespaceId:name:isPublic:)`` | `POST /orgs/{org}/teams {join: everyone \| invite}` |
/// | ``createContext(groupId:applicationId:name:initArgs:)`` / ``createServiceContext(groupId:applicationId:service:name:initArgs:)`` | `POST /apps {package (+ service) \| bundle, org, access: team \| org, initArgs}` |
/// | ``createInvitation(namespaceId:)`` / ``joinNamespace(namespaceId:invitation:)`` | `POST /orgs/{org}/invites`, `POST /invites/{token}/redeem` |
/// | ``events(contextId:)`` | `GET /apps/{app}/events` (sealed SSE) |
/// | contract `query` / `execute` | `POST /apps/{app}/views` / `POST /apps/{app}/intents` |
/// | blobs | `POST /apps/{app}/blobs`, `GET /apps/{app}/blobs/{id}` |
/// | names | org: metadata `name`; team: its name; app: metadata `name` (else its name) |
/// | members | `GET /orgs/{org}` / team; `POST …/members`, `DELETE …/members/{account}` |
///
/// A `groupId` is `"{orgId}/{teamId}"` for a team (``teamGroupId(org:team:)``)
/// or an org id for the org itself, as a namespace's root group was.
public final class CalimeroAppBackend: MeroAppBackend, Sendable {
    public let account: String
    public let client: CalimeroClient
    public let contract: any ContextContract
    /// The app's package: what an org is founded for and an app instance created from.
    public let packageName: String
    /// The package version new app instances run; the latest when `nil`.
    public let packageVersion: String?

    public init(client: CalimeroClient, account: String, packageName: String, packageVersion: String? = nil) {
        self.client = client
        self.account = account
        self.packageName = packageName
        self.packageVersion = packageVersion
        contract = CloudContextContract(client: client)
    }

    public var hasRelay: Bool { true }
    public var canSubscribe: Bool { true }

    // MARK: Groups

    /// Where `groupId` lives: an org (`team` nil), or a team of an org (`org/team`).
    func locate(_ groupId: String) -> (org: String, team: String?) {
        let ref = GroupRef.parse(groupId)
        return (ref.org, ref.team)
    }

    public func listNamespaces() async throws -> [AppNamespace] {
        let orgs = try await client.me().orgs
        let running = packageName.isEmpty ? [] : Set(try await client.listApps(package: packageName).compactMap(\.org))
        var out: [AppNamespace] = []
        for membership in orgs {
            let org = try await client.getOrg(membership.orgId)
            let mine = org.metadata["package"]?.stringValue == packageName || running.contains(org.orgId)
            guard packageName.isEmpty || mine else { continue }
            out.append(
                AppNamespace(
                    id: org.orgId, name: org.metadata["name"]?.stringValue ?? org.name, applicationId: packageName,
                    memberCount: org.members.count))
        }
        return out
    }

    public func listSubgroups(namespaceId: String) async throws -> [AppSubgroup] {
        let org = try await client.getOrg(namespaceId)
        var out: [AppSubgroup] = []
        for team in org.teams.values.sorted(by: { $0.name < $1.name }) {
            let apps = (try? await client.getTeam(namespaceId, team.teamId).apps.map(\.appId)) ?? []
            out.append(
                AppSubgroup(
                    groupId: teamGroupId(org: namespaceId, team: team.teamId), name: team.name, contextIds: apps))
        }
        return out
    }

    public func listContexts(groupId: String) async throws -> [String] {
        try await listContextEntries(groupId: groupId).map(\.id)
    }

    public func listContextEntries(groupId: String) async throws -> [AppContextEntry] {
        let place = locate(groupId)
        if let team = place.team {
            return try await client.getTeam(place.org, team).apps.map { AppContextEntry(id: $0.appId, name: $0.name) }
        }
        // The org's own: its apps that no team holds.
        let org = try await client.getOrg(place.org)
        var inTeams = Set<String>()
        for team in org.teams.keys {
            for app in (try? await client.getTeam(place.org, team).apps) ?? [] { inTeams.insert(app.appId) }
        }
        return try await client.listApps().filter { $0.org == place.org && !inTeams.contains($0.appId) }
            .map { AppContextEntry(id: $0.appId, name: $0.name) }
    }

    public func isMember(contextId: String) async throws -> Bool {
        do {
            _ = try await client.getApp(contextId)
            return true
        } catch is NotFound {
            return false
        }
    }

    public func joinContext(contextId: String) async throws {
        _ = try await client.getApp(contextId)
    }

    public func foundNamespace(name: String) async throws -> AppFoundedNamespace {
        let org = try await client.createOrg(name)
        var metadata: [String: JSONValue] = ["name": .string(name)]
        if !packageName.isEmpty { metadata["package"] = .string(packageName) }
        try await client.setOrgMetadata(org, .object(metadata))
        return AppFoundedNamespace(namespaceId: org)
    }

    public func createSubgroup(namespaceId: String, name: String, isPublic: Bool) async throws -> String {
        let team = try await client.createTeam(namespaceId, name: name, join: isPublic ? .everyone : .invite)
        return teamGroupId(org: namespaceId, team: team)
    }

    /// `applicationId` is a package (`package#service` for one service of a
    /// multi-service package), a bundle hash (dev clusters), or empty for the app's own package.
    public func createContext(
        groupId: String, applicationId: String, name: String, initArgs: JSONValue
    ) async throws -> String {
        let place = locate(groupId)
        var package = applicationId.isEmpty ? packageName : applicationId
        var service: String?
        if let hash = package.firstIndex(of: "#") {
            service = String(package[package.index(after: hash)...])
            package = String(package[..<hash])
        }
        let source: AppSource =
            Hex.is32(package) && service == nil
            ? .bundle(package)
            : .package(package, version: package == packageName ? packageVersion : nil, service: service)
        return try await client.createApp(
            name, bundle: source, org: place.org, access: place.team.map { .team($0) } ?? .org, initArgs: initArgs)
    }

    public func createServiceContext(
        groupId: String, applicationId: String, service: String, name: String, initArgs: JSONValue
    ) async throws -> String {
        try await createContext(
            groupId: groupId, applicationId: "\(applicationId.isEmpty ? packageName : applicationId)#\(service)",
            name: name, initArgs: initArgs)
    }

    public func createInvitation(namespaceId: String) async throws -> OrgInvitation {
        let name = try? await client.getOrg(namespaceId)
        return OrgInvitation(
            namespaceId: namespaceId, token: try await client.invite(namespaceId),
            name: name.map { $0.metadata["name"]?.stringValue ?? $0.name })
    }

    public func joinNamespace(namespaceId: String, invitation: OrgInvitation) async throws -> AppJoinedNamespace {
        let answer = try await client.redeemInvite(invitation.token)
        let org = answer["orgId"]?.stringValue ?? answer["org"]?.stringValue ?? invitation.namespaceId
        return AppJoinedNamespace(
            namespaceId: org.isEmpty ? namespaceId : org, published: true, nodeURL: await client.nodeUrl)
    }

    public func events(contextId: String) -> AsyncThrowingStream<AppContextEvent, Error> {
        let source = client.events(contextId)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        continuation.yield(
                            AppContextEvent(contextId: contextId, kind: event.kind, data: event.data, id: event.id))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Names

    public func groupMetadata(groupId: String) async throws -> AppMetadata? {
        let place = locate(groupId)
        if let team = place.team {
            let info = try await client.getTeam(place.org, team)
            return Self.metadata(info.metadata, name: info.name)
        }
        let org = try await client.getOrg(place.org)
        return Self.metadata(org.metadata, name: org.name)
    }

    public func contextMetadata(groupId: String, contextId: String) async throws -> AppMetadata? {
        let app = try await client.getApp(contextId)
        return Self.metadata(app["metadata"] ?? .null, name: app["name"]?.stringValue)
    }

    public func setGroupName(groupId: String, name: String) async throws {
        let place = locate(groupId)
        if let team = place.team {
            try await client.updateTeam(place.org, team, name: name)
            return
        }
        let org = try await client.getOrg(place.org)
        var metadata = org.metadata.objectValue ?? [:]
        metadata["name"] = .string(name)
        try await client.setOrgMetadata(place.org, .object(metadata))
    }

    public func setContextName(groupId: String, contextId: String, name: String) async throws {
        var metadata = try await client.getApp(contextId)["metadata"]?.objectValue ?? [:]
        metadata["name"] = .string(name)
        try await client.setAppMetadata(contextId, .object(metadata))
    }

    /// A record's name (its metadata's `name`, else `fallback`) and its other string fields.
    static func metadata(_ value: JSONValue, name fallback: String?) -> AppMetadata? {
        let fields = value.objectValue ?? [:]
        let name = fields["name"]?.stringValue ?? fallback.flatMap { $0.isEmpty ? nil : $0 }
        let data = fields.filter { $0.key != "name" }.compactMapValues(\.stringValue)
        if name == nil && data.isEmpty { return nil }
        return AppMetadata(name: name, data: data)
    }

    // MARK: Blobs

    public func uploadBlob(contextId: String, data: Data) async throws -> AppBlob {
        let blob = try await client.uploadBlob(contextId, data)
        return AppBlob(blobId: blob.blobId, size: blob.size)
    }

    public func getBlob(blobId: String, contextId: String) async throws -> Data {
        try await client.downloadBlob(contextId, blobId)
    }

    // MARK: Leaving and deleting

    public func leaveNamespace(namespaceId: String) async throws {
        try await client.removeMember(namespaceId, account: account)
    }

    public func leaveSubgroup(groupId: String) async throws {
        let place = locate(groupId)
        guard let team = place.team else {
            try await client.removeMember(place.org, account: account)
            return
        }
        try await client.removeTeamMember(place.org, team, account: account)
    }

    public func deleteSubgroup(groupId: String) async throws {
        let place = locate(groupId)
        guard let team = place.team else {
            throw AccountError.invalidInput("\(groupId) is an organization, not a team")
        }
        try await client.deleteTeam(place.org, team)
    }

    public func removeContext(groupId: String, contextId: String) async throws {
        try await client.deleteApp(contextId)
    }

    // MARK: Members

    public func listMembers(groupId: String) async throws -> [AppMember] {
        let place = locate(groupId)
        let org = try await client.getOrg(place.org)
        func name(_ account: String) -> String? { org.memberMetadata[account]?["name"]?.stringValue }
        if let team = place.team {
            return try await client.getTeam(place.org, team).members.map {
                AppMember(
                    identity: $0.account, role: GovernanceMemberRole($0.role).rawValue, name: name($0.account))
            }
        }
        return org.members.sorted { $0.key < $1.key }.map {
            AppMember(identity: $0.key, role: GovernanceMemberRole($0.value).rawValue, name: name($0.key))
        }
    }

    public func setMemberRole(groupId: String, identity: String, role: GovernanceMemberRole) async throws {
        let place = locate(groupId)
        if let team = place.team {
            try await client.setTeamMember(place.org, team, account: identity, role: role.teamRole)
        } else {
            try await client.setMember(place.org, account: identity, role: role.orgRole)
        }
    }

    public func removeMember(groupId: String, identity: String) async throws {
        let place = locate(groupId)
        if let team = place.team {
            try await client.removeTeamMember(place.org, team, account: identity)
        } else {
            try await client.removeMember(place.org, account: identity)
        }
    }

    public func setMemberName(groupId: String, name: String) async throws {
        let place = locate(groupId)
        let org = try await client.getOrg(place.org)
        var metadata = org.memberMetadata[account]?.objectValue ?? [:]
        metadata["name"] = .string(name)
        try await client.setMemberMetadata(place.org, account: account, .object(metadata))
    }
}
