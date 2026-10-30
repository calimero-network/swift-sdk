import Foundation
import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

// swiftlint:disable large_tuple cyclomatic_complexity function_body_length

/// A small cluster in memory behind a ``FakeCloudNode``: accounts' orgs,
/// teams, apps and invites, with the routes ``CloudAppBackend`` uses.
final class FakeCluster: @unchecked Sendable {
    static let me = "acc_me"
    private let lock = NSLock()
    var orgs:
        [String: (name: String, metadata: JSONValue, members: [String: String], memberMeta: [String: JSONValue])] =
            [:]
    var teams: [String: (org: String, name: String, join: String, members: [String: String])] = [:]
    var apps: [String: (name: String, org: String?, team: String?, package: String)] = [:]
    var next = 0

    func id(_ prefix: String) -> String {
        next += 1
        return "\(prefix)\(next)"
    }

    func handle(_ request: FakeCloudRequest) -> FakeCloudAnswer {
        lock.lock()
        defer { lock.unlock() }
        let parts = request.path.split(separator: "?")[0].split(separator: "/").map(String.init)
        let body = request.json ?? [:]
        func on(_ method: String, _ pattern: String) -> [String]? {
            let want = pattern.split(separator: "/").map(String.init)
            guard request.method == method, want.count == parts.count else { return nil }
            var wild: [String] = []
            for (w, p) in zip(want, parts) {
                if w == "*" { wild.append(p) } else if w != p { return nil }
            }
            return wild
        }
        let w: [String]
        switch true {
        case on("POST", "auth/passkey/login/begin") != nil:
            return .json(["challengeId": "c", "options": ["challenge": "AAAA", "rpId": "localhost"]])
        case on("POST", "auth/passkey/login/finish") != nil || on("POST", "auth/refresh") != nil:
            return .json([
                "accountId": .string(Self.me), "sessionToken": "v2.s", "expiresAt": 1_900_000_000,
                "refreshToken": "rt_s",
            ])
        case on("POST", "auth/logout") != nil:
            return .json([:])
        case on("GET", "auth/me") != nil:
            let mine = orgs.filter { $0.value.members[Self.me] != nil }.sorted { $0.key < $1.key }
            return .json([
                "accountId": .string(Self.me),
                "orgs": .array(
                    mine.map {
                        [
                            "orgId": .string($0.key), "name": .string($0.value.name),
                            "role": .string($0.value.members[Self.me]!),
                        ]
                    }),
            ])
        case on("POST", "orgs") != nil:
            let org = id("org")
            orgs[org] = (body["name"]?.stringValue ?? "", .null, [Self.me: "owner"], [:])
            return .json(["orgId": .string(org)])
        case on("GET", "orgs/*") != nil:
            w = on("GET", "orgs/*")!
            let org = w[0]
            guard let o = orgs[org] else { return .error(404, "NOT_FOUND") }
            var teamJSON: [String: JSONValue] = [:]
            for (tid, t) in teams where t.org == org {
                teamJSON[tid] = [
                    "teamId": .string(tid), "name": .string(t.name), "join": .string(t.join),
                    "members": .object(t.members.mapValues { .bool($0 == "lead") }),
                ]
            }
            return .json([
                "orgId": .string(org), "name": .string(o.name), "metadata": o.metadata,
                "members": .object(o.members.mapValues { .string($0) }), "teams": .object(teamJSON),
                "memberMetadata": .object(o.memberMeta),
            ])
        case on("POST", "orgs/*/metadata") != nil:
            w = on("POST", "orgs/*/metadata")!
            let org = w[0]
            orgs[org]?.metadata = body["metadata"] ?? .null
            return .json([:])
        case on("POST", "orgs/*/members/*/metadata") != nil:
            w = on("POST", "orgs/*/members/*/metadata")!
            let org = w[0]
            let account = w[1]
            orgs[org]?.memberMeta[account] = body["metadata"]
            return .json([:])
        case on("POST", "orgs/*/members") != nil:
            w = on("POST", "orgs/*/members")!
            let org = w[0]
            orgs[org]?.members[body["account"]?.stringValue ?? ""] = body["role"]?.stringValue
            return .json([:])
        case on("DELETE", "orgs/*/members/*") != nil:
            w = on("DELETE", "orgs/*/members/*")!
            let org = w[0]
            let account = w[1]
            orgs[org]?.members[account] = nil
            return .json([:])
        case on("POST", "orgs/*/teams") != nil:
            w = on("POST", "orgs/*/teams")!
            let org = w[0]
            let team = id("team")
            teams[team] = (
                org, body["name"]?.stringValue ?? "", body["join"]?.stringValue ?? "invite", [Self.me: "lead"]
            )
            return .json(["teamId": .string(team)])
        case on("GET", "orgs/*/teams/*") != nil:
            w = on("GET", "orgs/*/teams/*")!
            let team = w[1]
            guard let t = teams[team] else { return .error(404, "NOT_FOUND") }
            return .json([
                "teamId": .string(team), "name": .string(t.name), "join": .string(t.join),
                "members": .array(
                    t.members.map { entry -> JSONValue in
                        ["account": .string(entry.key), "role": .string(entry.value), "capabilities": 0]
                    }),
                "apps": .array(
                    apps.filter { $0.value.team == team }.sorted { $0.key < $1.key }.map {
                        ["appId": .string($0.key), "name": .string($0.value.name)]
                    }),
            ])
        case on("POST", "orgs/*/invites") != nil:
            w = on("POST", "orgs/*/invites")!
            let org = w[0]
            return .json(["token": .string("inv_\(org)")])
        case on("POST", "invites/*/redeem") != nil:
            w = on("POST", "invites/*/redeem")!
            let token = w[0]
            let org = String(token.dropFirst(4))
            orgs[org]?.members[Self.me] = "member"
            return .json(["orgId": .string(org)])
        case on("POST", "apps") != nil:
            let app = id("app")
            let access = body["access"]
            apps[app] = (
                body["name"]?.stringValue ?? "", body["org"]?.stringValue,
                access?["kind"] == "team" ? access?["team"]?.stringValue : nil, body["package"]?.stringValue ?? ""
            )
            return .json(["appId": .string(app)])
        case on("GET", "apps") != nil:
            let package = request.path.contains("package=") ? request.path.components(separatedBy: "package=")[1] : nil
            return .json([
                "apps": .array(
                    apps.filter { package == nil || $0.value.package == package }.sorted { $0.key < $1.key }.map {
                        [
                            "appId": .string($0.key), "name": .string($0.value.name), "owner": .string(Self.me),
                            "org": $0.value.org.map { .string($0) } ?? .null, "bundle": "b",
                            "package": .string($0.value.package),
                        ]
                    })
            ])
        case on("GET", "apps/*") != nil:
            w = on("GET", "apps/*")!
            let app = w[0]
            guard let a = apps[app] else { return .error(404, "NOT_FOUND") }
            return .json(["appId": .string(app), "name": .string(a.name)])
        default:
            return .error(404, "NOT_FOUND", message: "no route \(request.method) \(request.path)")
        }
    }
}

final class CloudAppBackendTests: XCTestCase {
    private var cluster: FakeCluster!
    private var node: FakeCloudNode!

    override func setUp() {
        super.setUp()
        cluster = FakeCluster()
        let cluster = self.cluster!
        node = FakeCloudNode { cluster.handle($0) }
        node.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func backend(package: String = "com.calimero.chat") async throws -> CloudAppBackend {
        let client = CalimeroClient(
            CalimeroClientOptions(
                baseUrl: "https://node.test", policy: .development, session: MockURLProtocol.makeSession()))
        try await client.signIn(SoftPasskey())
        return CloudAppBackend(client: client, account: FakeCluster.me, packageName: package)
    }

    func testFoundsAnOrgForTheAppAndListsOnlyThisAppsOrgs() async throws {
        let backend = try await backend()
        let founded = try await backend.foundNamespace(name: "Acme")
        XCTAssertTrue(founded.haEnabled)
        cluster.orgs["org_other"] = ("Other", ["package": "com.calimero.calendar"], [FakeCluster.me: "member"], [:])
        let listed = try await backend.listNamespaces()
        XCTAssertEqual(listed.map(\.id), [founded.namespaceId])
        XCTAssertEqual(listed.first?.name, "Acme")
        XCTAssertEqual(listed.first?.applicationId, "com.calimero.chat")
        XCTAssertEqual(cluster.orgs[founded.namespaceId]?.metadata["package"], "com.calimero.chat")
    }

    func testCreatesTeamsAndAppInstancesInThemAndListsThem() async throws {
        let backend = try await backend()
        let org = try await backend.foundNamespace(name: "Acme").namespaceId
        let team = try await backend.createSubgroup(namespaceId: org, name: "general", isPublic: true)
        XCTAssertEqual(cluster.teams[team]?.join, "everyone")
        let app = try await backend.createContext(
            groupId: team, applicationId: "com.calimero.chat", name: "general", initArgs: [:])
        let created = try XCTUnwrap(node.requests.last { $0.path == "/apps" }?.json)
        XCTAssertEqual(created["org"]?.stringValue, org)
        XCTAssertEqual(created["access"], ["kind": "team", "team": .string(team)])
        XCTAssertEqual(created["package"], "com.calimero.chat")

        let rootApp = try await backend.createContext(groupId: org, applicationId: "", name: "lobby", initArgs: [:])
        XCTAssertEqual(node.requests.last { $0.path == "/apps" }?.json?["access"], ["kind": "org"])

        let subgroups = try await backend.listSubgroups(namespaceId: org)
        XCTAssertEqual(subgroups, [AppSubgroup(groupId: team, name: "general", contextIds: [app])])
        let inTeam = try await backend.listContexts(groupId: team)
        XCTAssertEqual(inTeam, [app])
        let atRoot = try await backend.listContexts(groupId: org)
        XCTAssertEqual(atRoot, [rootApp])
        let member = try await backend.isMember(contextId: app)
        XCTAssertTrue(member)
        let stranger = try await backend.isMember(contextId: "app_nope")
        XCTAssertFalse(stranger)
    }

    func testAPerServiceAppInstanceNamesItsService() async throws {
        let backend = try await backend()
        let org = try await backend.foundNamespace(name: "Fleet").namespaceId
        _ = try await backend.createContext(
            groupId: org, applicationId: "com.calimero.battleships", name: "lobby", initArgs: [:], service: "lobby")
        XCTAssertEqual(node.requests.last { $0.path == "/apps" }?.json?["service"], "lobby")
    }

    func testInvitesWithATokenAndJoinsByRedeemingIt() async throws {
        let backend = try await backend()
        let org = try await backend.foundNamespace(name: "Acme").namespaceId
        let invitation = try await backend.createInvitation(namespaceId: org)
        XCTAssertEqual(invitation, OrgInvitation(orgId: org, token: "inv_\(org)"))
        cluster.orgs[org]?.members[FakeCluster.me] = nil
        let joined = try await backend.joinNamespace(namespaceId: org, invitation: invitation)
        XCTAssertEqual(joined.namespaceId, org)
        XCTAssertEqual(joined.nodeURL, "https://node.test")
        XCTAssertEqual(cluster.orgs[org]?.members[FakeCluster.me], "member")
    }

    func testMembersRolesAndNames() async throws {
        let backend = try await backend()
        let org = try await backend.foundNamespace(name: "Acme").namespaceId
        cluster.orgs[org]?.members["acc_guest"] = "guest"
        try await backend.setMemberName(groupId: org, name: "Ada")
        let members = try await backend.listMembers(groupId: org)
        XCTAssertEqual(
            members,
            [
                AppMember(identity: "acc_guest", role: "ReadOnly", name: nil),
                AppMember(identity: FakeCluster.me, role: "Admin", name: "Ada"),
            ])
        try await backend.setMemberRole(groupId: org, identity: "acc_guest", role: .member)
        XCTAssertEqual(cluster.orgs[org]?.members["acc_guest"], "member")
        try await backend.removeMember(groupId: org, identity: "acc_guest")
        XCTAssertNil(cluster.orgs[org]?.members["acc_guest"])
        try await backend.setGroupName(groupId: org, name: "Acme Inc")
        let renamed = try await backend.groupMetadata(groupId: org)
        XCTAssertEqual(renamed?.name, "Acme Inc")
        XCTAssertEqual(renamed?.data["package"], "com.calimero.chat")
    }
}

// swiftlint:enable large_tuple cyclomatic_complexity function_body_length
