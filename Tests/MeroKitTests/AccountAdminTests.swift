import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// What an ``AccountAdmin`` under test did with its deps.
final class AccountAdminRecorder: @unchecked Sendable {
    struct Governed: Equatable {
        let groupId: String
        let op: Warrants.GovernanceOp
    }

    private let lock = NSLock()
    private var _group: [Governed] = []
    private var _root: [Governed] = []
    private var _created: [CreateDelegatedContextRequest] = []
    private var _founded: [FoundingApplication?] = []
    private var _signed: [AccountInvitationInput] = []
    private var _joined: [String] = []
    private var _rootFailures: [Error] = []
    var rootGroupId: String
    var founded: FoundedDelegatedNamespace?

    init(rootGroupId: String) { self.rootGroupId = rootGroupId }

    var group: [Governed] { locked { _group } }
    var root: [Governed] { locked { _root } }
    var created: [CreateDelegatedContextRequest] { locked { _created } }
    var foundings: [FoundingApplication?] { locked { _founded } }
    var signed: [AccountInvitationInput] { locked { _signed } }
    var joined: [String] { locked { _joined } }

    /// Make the next root op throw `error`.
    func failNextRoot(_ error: Error) { locked { _rootFailures.append(error) } }

    func deps(
        join: AccountAdminDeps.Join? = nil, routing: AccountAdminDeps.Routing? = nil
    ) -> AccountAdminDeps {
        AccountAdminDeps(
            governGroup: { [self] _, groupId, op in
                locked { _group.append(Governed(groupId: groupId, op: op)) }
                return groupId
            },
            governRoot: { [self] _, groupId, op in
                let failure: Error? = locked {
                    _root.append(Governed(groupId: groupId, op: op))
                    return _rootFailures.isEmpty ? nil : _rootFailures.removeFirst()
                }
                if let failure { throw failure }
                return rootGroupId
            },
            createContext: { [self] _, request in
                locked { _created.append(request) }
                return CreatedRelayContext(
                    contextId: AccountAdminTests.ctx, groupId: request.groupId ?? "", memberPublicKey: "relay")
            },
            found: { [self] _, _, application in
                locked { _founded.append(application) }
                return founded
                    ?? FoundedDelegatedNamespace(
                        namespaceId: AccountAdminTests.ns, salt: "", teeEnabled: true, haEnabled: true, haError: nil,
                        defaultCapabilitiesSet: true)
            },
            latestVersion: { _, _ in "1.2.3" },
            signInvitation: { [self] input in
                locked { _signed.append(input) }
                return SignedGroupOpenInvitation(
                    invitation: GroupInvitationFromAdmin(
                        inviterIdentity: [], groupId: [], expirationTimestamp: 0, secretSalt: [], invitedRole: 1,
                        admitters: input.admitters),
                    inviterSignature: "sig")
            },
            join: join, routing: routing)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Port of mero-js `account/account-admin.test.ts` and `node-admin.test.ts`.
final class AccountAdminTests: XCTestCase {
    static let ns = DelegatedFixture.rep("01")
    static let sub = DelegatedFixture.rep("02")
    static let ctx = DelegatedFixture.rep("03")
    private let other = DelegatedFixture.rep("04")
    private let bob = DelegatedFixture.rep("bb")
    private var rig: CloudRig!
    private var recorder: AccountAdminRecorder!
    private var session: DelegatedSession { DelegatedFixture.session() }
    private var me: String { session.account }

    override func setUp() {
        super.setUp()
        rig = CloudRig()
        rig.install()
        recorder = AccountAdminRecorder(rootGroupId: Self.sub)
        serveMembers([(me, "Admin")])
        rig.on("GET", "/admin-api/contexts/\(Self.ctx)/group", json: #"{"data":"\#(Self.sub)"}"#)
        for group in [Self.ns, Self.sub, other] { serveGroupInfo(group) }
        let listed = [
            namespace(Self.ns, app: DelegatedFixture.rep("0a")), namespace(Self.sub, app: DelegatedFixture.rep("0b")),
        ]
        rig.on("GET", "/admin-api/namespaces", json: #"{"data":[\#(listed.joined(separator: ","))]}"#)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        rig = nil
        recorder = nil
        super.tearDown()
    }

    private func namespace(_ id: String, app: String) -> String {
        #"{"namespaceId":"\#(id)","appKey":"k","targetApplicationId":"\#(app)","createdAt":0,"memberCount":1,"#
            + #""contextCount":0,"subgroupCount":0}"#
    }

    private func serveGroupInfo(_ groupId: String) {
        rig.on(
            "GET", "/admin-api/groups/\(groupId)",
            json: """
                {"data":{"groupId":"\(groupId)","appKey":"\(DelegatedFixture.rep("12"))",
                 "targetApplicationId":"\(DelegatedFixture.rep("34"))","memberCount":1,"contextCount":0,
                 "defaultCapabilities":231,"subgroupVisibility":"open","namespaceId":"\(Self.ns)"}}
                """)
    }

    private func serveMembers(_ members: [(String, String)], group: String? = nil) {
        let listed = members.map { #"{"identity":"\#($0.0)","role":"\#($0.1)"}"# }.joined(separator: ",")
        for id in group.map({ [$0] }) ?? [Self.ns, Self.sub] {
            rig.on("GET", "/admin-api/groups/\(id)/members", json: #"{"members":[\#(listed)]}"#)
        }
    }

    private func admin(
        relay: Bool = true, join: AccountAdminDeps.Join? = nil, routing: AccountAdminDeps.Routing? = nil
    ) -> AccountAdmin {
        let read = AdminApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: DelegatedFixture.relay)!, session: MockURLProtocol.makeSession()))
        return AccountAdmin(
            session: relay ? session : session.on(relay: nil), read: relay ? read : nil,
            app: AdminAppConfig(packageName: "com.calimero.chat", registryURL: "https://reg"),
            env: DelegatedFixture.environment(), deps: recorder.deps(join: join, routing: routing))
    }

    private func governed(_ groupId: String, _ op: Warrants.GovernanceOp) -> AccountAdminRecorder.Governed {
        AccountAdminRecorder.Governed(groupId: groupId, op: op)
    }

    private func directMemberRefusal() -> Error {
        MeroError.http(
            HTTPError(
                status: 409, statusText: "Conflict", url: "", headers: [:],
                bodyText: #"{"error":"signer \#(me) is a direct member; use MemberJoined or add_group_members"}"#))
    }

    private func assertRefused(
        _ expected: AccountError, file: StaticString = #filePath, line: UInt = #line, _ call: () async throws -> Void
    ) async {
        do {
            try await call()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountError, expected, file: file, line: line)
        }
    }

    // MARK: - Reads

    func testReadsGoToTheRelayReadClientUnchanged() async throws {
        let namespaces = try await admin().listNamespaces()
        XCTAssertEqual(namespaces.count, 2)
        XCTAssertEqual(rig.requests("GET", "/admin-api/namespaces").count, 1)
        let info = try await admin().getGroupInfo(Self.sub)
        XCTAssertEqual(info.groupId, Self.sub)
    }

    func testListsItsNamespacesForAnApplicationFromItsOwnScopedList() async throws {
        let listed = try await admin().listNamespacesForApplication(DelegatedFixture.rep("0a"))
        XCTAssertEqual(listed.map(\.namespaceId), [Self.ns])
        let forApplication = "/admin-api/namespaces/for-application/\(DelegatedFixture.rep("0a"))"
        XCTAssertTrue(rig.requests("GET", forApplication).isEmpty)
    }

    func testIsTheAccountItselfWhenAskedWhoItIs() async throws {
        let identity = try await admin().getNodeIdentity()
        XCTAssertEqual(identity.accountId, me)
    }

    func testReadsItsGroupsUpgradeMigrationAndCascadeStatusFromTheRelay() async throws {
        rig.on("GET", "/admin-api/groups/\(Self.ns)/cascade-status", json: #"{"data":[]}"#)
        let cascade = try await admin().getCascadeStatus(Self.ns)
        XCTAssertTrue(cascade.isEmpty)
        XCTAssertEqual(rig.requests("GET", "/admin-api/groups/\(Self.ns)/cascade-status").count, 1)
    }

    // MARK: - Groups

    func testCreatesASubgroupThroughTheNamespaceAndRemembersIt() async throws {
        let created = try await admin().createGroupInNamespace(
            Self.ns, request: CreateGroupInNamespaceRequest(groupName: "general", visibility: "open"))
        XCTAssertEqual(created.groupId, Self.sub)
        XCTAssertEqual(recorder.root.map(\.groupId), [Self.ns])
        XCTAssertEqual(recorder.root.first?.op.kind, .root)
        XCTAssertEqual(recorder.group, [governed(Self.sub, GovernanceOps.groupMetadataSet(name: "general"))])
    }

    func testCreatesASubgroupOpenUnlessAskedForRestricted() async throws {
        // GroupCreated: tag, groupId (32), parentId (32), then the restricted flag.
        _ = try await admin().createGroupInNamespace(Self.ns)
        _ = try await admin().createGroupInNamespace(
            Self.ns, request: CreateGroupInNamespaceRequest(visibility: "restricted"))
        let flags = recorder.root.map { $0.op.bytes[$0.op.bytes.startIndex + 1 + 32 + 32] }
        XCTAssertEqual(flags, [0, 1])
    }

    func testMemberMetadataVisibilityAndCapabilityWritesAreGroupOpsOnTheNamedGroup() async throws {
        let admin = self.admin()
        let sub = Self.sub
        try await admin.addGroupMembers(
            sub, request: AddGroupMembersRequest(members: [GroupMemberInput(identity: bob, role: "Member")]))
        try await admin.removeGroupMembers(sub, request: RemoveGroupMembersRequest(members: [bob]))
        try await admin.setGroupMetadata(sub, request: SetMetadataRequest(name: "general"))
        try await admin.setMemberMetadata(sub, identity: bob, request: SetMetadataRequest(name: "Bob"))
        try await admin.setContextMetadata(sub, contextId: Self.ctx, request: SetMetadataRequest(name: "room"))
        try await admin.setDefaultCapabilities(sub, request: SetDefaultCapabilitiesRequest(defaultCapabilities: 231))
        try await admin.setSubgroupVisibility(
            sub, request: SetSubgroupVisibilityRequest(subgroupVisibility: "restricted"))
        try await admin.setMemberCapabilities(
            sub, identity: bob, request: SetMemberCapabilitiesRequest(capabilities: 1))
        XCTAssertEqual(recorder.group.count, 8)
        XCTAssertTrue(recorder.group.allSatisfy { $0.groupId == sub })
        XCTAssertEqual(recorder.group[6].op, GovernanceOps.subgroupVisibilitySet(.restricted))
    }

    func testDeleteAndReparentAreRootOpsAndLeavingIsMyOwnMemberLeft() async throws {
        let admin = self.admin()
        let deleted = try await admin.deleteGroup(Self.sub)
        XCTAssertTrue(deleted.isDeleted)
        let moved = try await admin.reparentGroup(Self.sub, request: ReparentGroupRequest(newParentId: Self.ns))
        XCTAssertTrue(moved.reparented)
        XCTAssertEqual(recorder.root.count, 2)
        try await admin.leaveGroup(Self.sub)
        XCTAssertEqual(recorder.group.last, governed(Self.sub, try GovernanceOps.memberLeft(me)))
    }

    func testGovernsASubgroupItWasNeverToldAboutAskingTheRelayOnce() async throws {
        let admin = self.admin()
        try await admin.setGroupMetadata(other, request: SetMetadataRequest(name: "a"))
        try await admin.setGroupMetadata(other, request: SetMetadataRequest(name: "b"))
        XCTAssertEqual(rig.requests("GET", "/admin-api/groups/\(other)").count, 1)
    }

    func testSetsAMembersRoleAsMemberRoleSet() async throws {
        try await admin().updateMemberRole(Self.sub, identity: bob, request: UpdateMemberRoleRequest(role: "Admin"))
        XCTAssertEqual(recorder.group, [governed(Self.sub, try GovernanceOps.memberRoleSet(bob, role: .admin))])
    }

    func testDetachesAContextAsContextDetached() async throws {
        try await admin().detachContextFromGroup(Self.sub, contextId: Self.ctx)
        XCTAssertEqual(recorder.group, [governed(Self.sub, try GovernanceOps.contextDetached(Self.ctx))])
    }

    // MARK: - Joining a context or subgroup

    func testJoinsAContextWithMemberJoinedOpenOnItsGroup() async throws {
        let joined = try await admin().joinContext(Self.ctx)
        XCTAssertEqual(joined.memberPublicKey, me)
        let expected = try GovernanceOps.memberJoinedOpen(member: me, groupId: Self.sub, credential: session.credential)
        XCTAssertEqual(recorder.root, [governed(Self.sub, expected)])
    }

    func testADirectMembersJoinIsANoOpAndAnyOtherRefusalIsAnError() async throws {
        recorder.failNextRoot(directMemberRefusal())
        _ = try await admin().joinContext(Self.ctx)
        recorder.failNextRoot(directMemberRefusal())
        let inherited = try await admin().joinSubgroupInheritance(Self.sub)
        XCTAssertFalse(inherited.wasInherited)
        let fresh = try await admin().joinSubgroupInheritance(Self.sub)
        XCTAssertTrue(fresh.wasInherited)

        recorder.failNextRoot(
            MeroError.http(
                HTTPError(
                    status: 403, statusText: "Forbidden", url: "", headers: [:],
                    bodyText: #"{"error":"signer has no membership path"}"#)))
        do {
            _ = try await admin().joinContext(Self.ctx)
            XCTFail("a refusal that is not the direct-member no-op is an error")
        } catch {
            XCTAssertEqual(classifyError(error).status, 403)
        }
    }

    func testOwnsItsAccountInAContextOnlyOnceAMemberOfItsGroup() async throws {
        let owned = try await admin().getContextIdentitiesOwned(Self.ctx)
        XCTAssertEqual(owned.identities, [me])
        serveMembers([(bob, "Admin")])
        let notOwned = try await admin().getContextIdentitiesOwned(Self.ctx)
        XCTAssertTrue(notOwned.identities.isEmpty)
    }

    // MARK: - Creating

    func testCreatesAContextThroughTheRelayNamingTheAccountAsItsMember() async throws {
        let created = try await admin().createContext(
            CreateContextRequest(
                applicationId: DelegatedFixture.rep("ap"), groupId: Self.sub, serviceName: "registry",
                contextSeed: DelegatedFixture.rep("ff"), initializationParams: [], name: "room"))
        XCTAssertEqual(created.contextId, Self.ctx)
        XCTAssertEqual(created.memberPublicKey, me)
        XCTAssertEqual(created.groupId, Self.sub)
        XCTAssertEqual(
            recorder.created,
            [
                CreateDelegatedContextRequest(
                    namespaceId: Self.ns, groupId: Self.sub, applicationId: DelegatedFixture.rep("ap"),
                    serviceName: "registry", contextSeed: DelegatedFixture.rep("ff"), initializationParams: [],
                    name: "room")
            ])
    }

    func testFoundsANamespaceWithThisAppsPackageAtTheLatestVersionAndCarriesHa() async throws {
        recorder.founded = FoundedDelegatedNamespace(
            namespaceId: Self.ns, salt: "", teeEnabled: true, haEnabled: false, haError: "link it",
            defaultCapabilitiesSet: true)
        let created = try await admin().createNamespace(
            CreateNamespaceRequest(applicationId: DelegatedFixture.rep("ap"), name: "Team"))
        XCTAssertEqual(created.namespaceId, Self.ns)
        XCTAssertEqual(created.haEnabled, false)
        XCTAssertEqual(created.haError, "link it")
        let expected = FoundingApplication(
            applicationId: DelegatedFixture.rep("ap"), package: "com.calimero.chat", version: "1.2.3")
        XCTAssertEqual(recorder.foundings, [expected])
        XCTAssertEqual(recorder.group, [governed(Self.ns, GovernanceOps.groupMetadataSet(name: "Team"))])
    }

    // MARK: - Inviting

    func testSignsAnInvitationItselfNamingTheNamespacesRelays() async throws {
        let relayAccount = DelegatedFixture.rep("ee")
        serveMembers([(me, "Admin"), (relayAccount.uppercased(), "RelayTee"), (bob, "Member")])
        guard case .single(let out) = try await admin().createNamespaceInvitation(Self.ns) else {
            return XCTFail("a single invitation")
        }
        XCTAssertEqual(out.invitation.inviterSignature, "sig")
        let input = try XCTUnwrap(recorder.signed.first)
        XCTAssertEqual(input.groupId, Self.ns)
        XCTAssertEqual(input.inviterAccount, me)
        XCTAssertEqual(input.admitters, [relayAccount])
        XCTAssertEqual(input.applicationId, DelegatedFixture.rep("34"))
        XCTAssertEqual(input.appKey, DelegatedFixture.rep("12"))
    }

    func testFallsBackToTheAdminsWhenTheNamespaceHasNoRelay() async throws {
        _ = try await admin().createNamespaceInvitation(Self.ns)
        XCTAssertEqual(recorder.signed.first?.admitters, [], "GroupInvitations.sign defaults them to the admins")
    }

    func testMintsOnlyAnInvitationSomeoneCouldClaim() async throws {
        let relayAccount = DelegatedFixture.rep("ee")
        let bob = self.bob
        serveMembers([(me, "Admin"), (relayAccount, "RelayTee")])
        _ = try await admin(routing: { _ in [relayAccount.uppercased()] }).createNamespaceInvitation(Self.ns)
        XCTAssertEqual(recorder.signed.count, 1)

        await assertRefused(.invitationNotClaimable(namespaceId: Self.ns, reason: "not-hosted")) {
            _ = try await self.admin(routing: { _ in [] }).createNamespaceInvitation(Self.ns)
        }
        await assertRefused(.invitationNotClaimable(namespaceId: Self.ns, reason: "no-named-node")) {
            _ = try await self.admin(routing: { _ in [bob, nil] }).createNamespaceInvitation(Self.ns)
        }
        XCTAssertEqual(recorder.signed.count, 1, "nothing signed for an invitation nobody could claim")
        let notHosted = AccountError.invitationNotClaimable(namespaceId: Self.ns, reason: "not-hosted")
        XCTAssertEqual(notHosted.invitationNotClaimableReason, .notHosted)

        // A failed lookup says nothing: minting is not refused over a blip.
        let offline = admin(routing: { _ in throw URLError(.notConnectedToInternet) })
        _ = try await offline.createNamespaceInvitation(Self.ns)
        XCTAssertEqual(recorder.signed.count, 2)
    }

    func testChecksTheAdminsWhenTheNamespaceHasNoRelay() async throws {
        let account = me
        _ = try await admin(routing: { _ in [account] }).createNamespaceInvitation(Self.ns)
        XCTAssertEqual(recorder.signed.count, 1)
    }

    // MARK: - Joining a namespace

    func testJoinsANamespaceThroughTheJoinHandlerWithOrWithoutARelay() async throws {
        let calls = DelegatedLog()
        let join: AccountAdminDeps.Join = { namespaceId, _ in
            calls.add(namespaceId)
            return namespaceId
        }
        let invitation = SignedGroupOpenInvitation(
            invitation: GroupInvitationFromAdmin(
                inviterIdentity: [], groupId: [], expirationTimestamp: 0, secretSalt: [], invitedRole: 1,
                admitters: []),
            inviterSignature: "sig")
        for relay in [true, false] {
            let joined = try await admin(relay: relay, join: join).joinNamespace(
                Self.ns, request: JoinNamespaceRequest(invitation: invitation))
            XCTAssertEqual(joined.namespaceId, Self.ns)
        }
        XCTAssertEqual(calls.all, [Self.ns, Self.ns])
        await assertRefused(.notForAccount(method: "joinNamespace without a join handler")) {
            _ = try await self.admin().joinNamespace(Self.ns, request: JoinNamespaceRequest(invitation: invitation))
        }
    }

    // MARK: - Refusals

    func testSyncingIsANoOpForAnAccount() async throws {
        let synced = try await admin().syncGroup(Self.ns)
        XCTAssertEqual(synced.groupId, Self.ns)
        try await admin().syncContext(Self.ctx)
        XCTAssertTrue(recorder.group.isEmpty)
    }

    func testRefusesByNameWhatHasNoAccountForm() async throws {
        let admin = self.admin()
        let upgrade = UpgradeGroupRequest(targetApplicationId: "a")
        let install = InstallApplicationRequest(package: "p", version: "1")
        let refused: [(String, () async throws -> Void)] = [
            ("upgradeGroup", { _ = try await admin.upgradeGroup(Self.ns, request: upgrade) }),
            ("installApplication", { _ = try await admin.installApplication(install) }),
            ("deleteContext", { _ = try await admin.deleteContext(Self.ctx) }),
            ("leaveContext", { try await admin.leaveContext(Self.ctx) }),
            ("deleteContextAlias", { _ = try await admin.deleteContextAlias("a") }),
            ("lookupContextAlias", { _ = try await admin.lookupContextAlias("a") }),
            ("listContextAliases", { _ = try await admin.listContextAliases() }),
            ("listDeviceAliases", { _ = try await admin.listDeviceAliases() }),
            ("deleteNamespace", { _ = try await admin.deleteNamespace(Self.ns) }),
            ("createGroupInvitation", { _ = try await admin.createGroupInvitation(Self.sub) }),
            ("getTeeAdmissionPolicy", { _ = try await admin.getTeeAdmissionPolicy(Self.ns) }),
            ("deleteBlob", { _ = try await admin.deleteBlob("b") }),
            ("listAccountDevices", { _ = try await admin.listAccountDevices() }),
        ]
        for (name, call) in refused {
            await assertRefused(.notForAccount(method: name), call)
        }
        XCTAssertTrue(recorder.group.isEmpty)
        XCTAssertTrue(recorder.root.isEmpty)
        XCTAssertTrue(rig.seen.isEmpty, "never sent to a node route")
    }

    // MARK: - No relay yet

    func testWithNoRelayTheAccountIsAMemberOfNothing() async throws {
        let fresh = admin(relay: false)
        let namespaces = try await fresh.listNamespaces()
        let contexts = try await fresh.getContexts()
        let forApp = try await fresh.listNamespacesForApplication(DelegatedFixture.rep("0a"))
        XCTAssertTrue(namespaces.isEmpty)
        XCTAssertTrue(contexts.contexts.isEmpty)
        XCTAssertTrue(forApp.isEmpty)
        let identity = try await fresh.getNodeIdentity()
        XCTAssertEqual(identity.accountId, me)
        await assertRefused(.noRelay(method: "this call")) { _ = try await fresh.getGroupInfo(Self.ns) }
        await assertRefused(.noRelay(method: "setGroupMetadata")) {
            try await fresh.setGroupMetadata(Self.ns, request: SetMetadataRequest(name: "x"))
        }
        await assertRefused(.noRelay(method: "upgradeGroup")) {
            _ = try await fresh.upgradeGroup(Self.ns, request: UpgradeGroupRequest(targetApplicationId: "a"))
        }
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testRefusalsClassifyAsForbiddenAndUnavailable() {
        XCTAssertEqual(classifyError(AccountError.notForAccount(method: "x")).kind, .forbidden)
        XCTAssertEqual(classifyError(AccountError.noRelay(method: "x")).kind, .unavailable)
        XCTAssertTrue(AccountError.notForAccount(method: "upgradeGroup").localizedDescription.contains("needs a node"))
    }

    // MARK: - Node admin

    private func nodeAdmin(installedAs: String) -> NodeAdmin {
        rig.on("POST", "/admin-api/install-application", json: #"{"data":{"applicationId":"\#(installedAs)"}}"#)
        rig.on("POST", "/admin-api/namespaces", json: #"{"data":{"namespaceId":"\#(Self.ns)"}}"#)
        let http = URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession())
        let admin = AdminApi(http: http)
        return NodeAdmin(
            admin: admin, app: AdminAppConfig(packageName: "com.calimero.chat"), latestVersion: { _, _ in "1.2.3" })
    }

    private func serveApplications(_ ids: [String]) {
        let apps = ids.map {
            #"{"id":"\#($0)","blob":{"bytecode":"b","compiled":"c"},"size":0,"source":"s","metadata":[],"#
                + #""signer_id":"did:key:z","package":"com.calimero.chat","version":"1.2.3"}"#
        }
        rig.on("GET", "/admin-api/applications", json: #"{"data":{"apps":[\#(apps.joined(separator: ","))]}}"#)
    }

    func testNodeAdminCreatesStraightAwayWhenTheAppIsInstalled() async throws {
        serveApplications([DelegatedFixture.rep("ap")])
        let created = try await nodeAdmin(installedAs: "x").createNamespace(
            CreateNamespaceRequest(applicationId: DelegatedFixture.rep("ap")))
        XCTAssertEqual(created.namespaceId, Self.ns)
        XCTAssertTrue(rig.requests("POST", "/admin-api/install-application").isEmpty)
    }

    func testNodeAdminInstallsTheAppFromTheRegistryFirst() async throws {
        serveApplications([])
        _ = try await nodeAdmin(installedAs: DelegatedFixture.rep("ap")).createNamespace(
            CreateNamespaceRequest(applicationId: DelegatedFixture.rep("ap")))
        let install = try XCTUnwrap(rig.requests("POST", "/admin-api/install-application").first?.json)
        XCTAssertEqual(install, ["package": "com.calimero.chat", "version": "1.2.3"])
        XCTAssertEqual(rig.requests("POST", "/admin-api/namespaces").count, 1)
    }

    func testNodeAdminRefusesARegistryBundleThatIsAnotherApp() async throws {
        serveApplications([])
        do {
            _ = try await nodeAdmin(installedAs: DelegatedFixture.rep("zz")).createNamespace(
                CreateNamespaceRequest(applicationId: DelegatedFixture.rep("ap")))
            XCTFail("a different application id must not be founded on")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not \(DelegatedFixture.rep("ap"))"))
        }
        XCTAssertTrue(rig.requests("POST", "/admin-api/namespaces").isEmpty)
    }

    func testNodeAdminPassesEveryOtherCallThrough() async throws {
        let namespaces = try await nodeAdmin(installedAs: "x").listNamespaces()
        XCTAssertEqual(namespaces.count, 2)
        let surface: any AdminSurface = nodeAdmin(installedAs: "x")
        let info = try await surface.getGroupInfo(Self.ns)
        XCTAssertEqual(info.namespaceId, Self.ns)
    }
}
