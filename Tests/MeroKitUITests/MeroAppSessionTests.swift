import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// A wallet that answers the auth sheet in-process (as in
/// `MeroClientCloudTests`): the real verification path runs, with no browser.
private struct AppSessionWallet: WebAuthenticating {
    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let root = Data(repeating: 0x5C, count: 32)
        let account = try DeviceCertificates.account(forRootPublicKey: Hex.encode(try Ed25519.publicKey(seed: root)))
        let device = try DeviceCertificates.mintDeviceId(account: account, nonce: Data(repeating: 0xA1, count: 16))
        let credential = try DeviceCertificates.certify(
            rootSeed: root, device: device, signPublicKey: item("enrol-device"), kemPublicKey: item("enrol-kem"))
        return URL(
            string:
                "\(item("callback-url"))#credential=\(credential)&account=\(account)&device=\(device)&state=\(item("state"))"
        )!
    }
}

@MainActor
final class MeroAppSessionTests: XCTestCase {
    private static let package = "com.example.board"
    private static let mine = String(repeating: "ad", count: 32)
    private static let theirs = String(repeating: "be", count: 32)

    override func setUp() {
        super.setUp()
        MockURLProtocol.setHandler { req in
            let path = req.url?.path ?? ""
            func json(_ s: String) -> MockURLProtocol.Stub {
                .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
            }
            if path.hasSuffix("/challenge"), path.hasPrefix("/api/cloud/") { return json(#"{"nonce":"n"}"#) }
            if path.hasSuffix("/relays") {
                return json(#"{"relays":[{"peer_id":"p","relay_url":"https://relay.test","fresh":true}]}"#)
            }
            if path == "/admin-api/tee/attest" {
                let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
                let nonce = (try? Hex.decode(body?["nonce"] as? String ?? "", label: "n", bytes: 32)) ?? Data()
                let key = try! Ed25519.publicKey(seed: Data(repeating: 0x42, count: 32))
                let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(key)
                return json(
                    #"{"data":{"quoteB64":"\#(quote.base64EncodedString())","boundPublicKey":"\#(Hex.encode(key))"}}"#)
            }
            if path == "/auth/challenge" {
                return json(#"{"data":{"challenge":"\#(String(repeating: "c4", count: 32))"}}"#)
            }
            if path == "/auth/token" { return json(#"{"data":{"access_token":"a","refresh_token":"r"}}"#) }
            if path == "/auth/logout" { return json(#"{"data":{"success":true}}"#) }
            if path.hasSuffix("/query") { return json(#"{"data":{"returns":{"posts":42}}}"#) }
            if path == "/admin-api/namespaces" {
                func namespace(_ id: String, app: String, name: String) -> String {
                    #"{"namespaceId":"\#(id)","appKey":"k","targetApplicationId":"\#(app)","createdAt":1,"#
                        + #""name":"\#(name)","memberCount":2,"contextCount":0,"subgroupCount":0}"#
                }
                let board = namespace(Self.mine, app: "BoardApp", name: "Board")
                let chat = namespace(Self.theirs, app: "ChatApp", name: "Chat")
                return json(#"{"data":[\#(board),\#(chat)]}"#)
            }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession(package: String? = MeroAppSessionTests.package) -> MeroAppSession {
        let urlSession = MockURLProtocol.makeSession()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: DcapRelayKeyVerifier(allowMock: true), sealRelays: false),
            keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore(), urlSession: urlSession)
        let client = MeroClient(
            session: urlSession, cloud: cloud, webAuthenticator: AppSessionWallet(),
            config: MeroProviderConfig(packageName: package, registryURL: "https://registry.test"),
            storage: MeroAppStorage(defaults: appLayerDefaults()))
        return MeroAppSession(client: client, callback: .scheme("board"))
    }

    func testSignedOutHasNoBackendAndARelaylessContract() async {
        let session = makeSession()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.backend)
        XCTAssertFalse(session.hasRelay)
        XCTAssertFalse(session.canSubscribe)
        do {
            _ = try await session.contract.bound(to: Self.mine).query(method: "feed", argsJSON: Data())
            XCTFail("expected noRelay")
        } catch AccountError.noRelay(let method) {
            XCTAssertEqual(method, "feed")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSignInBuildsTheBackendOverTheRelay() async throws {
        let session = makeSession()
        let before = session.revision
        await session.signIn()

        XCTAssertNil(session.client.errorMessage)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.account?.count, 64)
        let backend = try XCTUnwrap(session.backend)
        XCTAssertEqual(backend.account, session.account)
        XCTAssertTrue(session.hasRelay)
        XCTAssertTrue(session.canSubscribe, "the relay session was minted")
        XCTAssertGreaterThan(session.revision, before)
        XCTAssertTrue(backend.contract is RelayContextContract)

        let answer = try await session.contract.bound(to: Self.mine).query(method: "feed", argsJSON: Data("{}".utf8))
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), #"{"posts":42}"#)

        await session.signOut()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.backend)
    }

    func testRebuildIsANoOpWhenNothingChanged() async {
        let session = makeSession()
        await session.signIn()
        await Task.yield()
        session.rebuild()
        let settled = session.revision
        session.rebuild()
        session.rebuild()
        XCTAssertEqual(session.revision, settled, "open screens are not reset by an unchanged session")
    }

    func testRestoreWithNothingStoredStaysSignedOut() async {
        let session = makeSession()
        await session.restore()
        XCTAssertFalse(session.isRestoring)
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.backend)
    }

    func testListingKeepsOnlyThisAppsNamespaces() async throws {
        let session = makeSession()
        await session.signIn()
        let client = session.client
        let connection = try XCTUnwrap(client.connection)
        let admin = try XCTUnwrap(client.admin)
        let mine = DelegatedAppBackend(
            connection: connection, admin: admin, signIn: client.cloudSignIn, packageName: Self.package,
            applicationId: "boardapp")
        let every = DelegatedAppBackend(
            connection: connection, admin: admin, signIn: client.cloudSignIn, packageName: Self.package)

        let filtered = try await mine.listNamespaces()
        XCTAssertEqual(
            filtered, [AppNamespace(id: Self.mine, name: "Board", applicationId: "BoardApp", memberCount: 2)])
        let all = try await every.listNamespaces()
        XCTAssertEqual(all.map(\.id), [Self.mine, Self.theirs])
    }

    /// Names, blobs, leaving and members map onto the account admin's calls,
    /// which ``AccountAdmin`` turns into reads and governance ops on the relay.
    func testTheBackendsNamesBlobsLeavingAndMembersGoThroughTheAdmin() async throws {
        let session = makeSession()
        await session.signIn()
        let client = session.client
        let admin = RecordingAdmin()
        let me = try XCTUnwrap(client.account)
        admin.contexts = [GroupContextEntry(contextId: "c1", name: "Roadmap"), GroupContextEntry(contextId: "c2")]
        admin.members = [
            GroupMember(identity: me, role: "Admin", name: "Ana"), GroupMember(identity: "b", role: "Member"),
        ]
        admin.metadata = [
            "g": MetadataRecord(name: "boards", data: ["icon": "grid"], updatedAt: 1, updatedBy: me),
            "c1": MetadataRecord(name: "Roadmap", data: ["color": "red"], updatedAt: 1, updatedBy: me),
            me: MetadataRecord(name: "Ana", data: ["avatar": "a1"], updatedAt: 1, updatedBy: me),
        ]
        let backend = DelegatedAppBackend(
            connection: try XCTUnwrap(client.connection), admin: admin, signIn: client.cloudSignIn,
            packageName: Self.package)

        let entries = try await backend.listContextEntries(groupId: "g")
        XCTAssertEqual(entries, [AppContextEntry(id: "c1", name: "Roadmap"), AppContextEntry(id: "c2", name: nil)])
        let groupMeta = try await backend.groupMetadata(groupId: "g")
        XCTAssertEqual(groupMeta, AppMetadata(name: "boards", data: ["icon": "grid"]))
        let contextMeta = try await backend.contextMetadata(groupId: "g", contextId: "c1")
        XCTAssertEqual(contextMeta?.name, "Roadmap")
        let none = try await backend.groupMetadata(groupId: "unnamed")
        XCTAssertNil(none)
        try await backend.setGroupName(groupId: "g", name: "planning")
        try await backend.setContextName(groupId: "g", contextId: "c1", name: "Q3")
        try await backend.setMemberName(groupId: "g", name: "Ana B")

        let blob = try await backend.uploadBlob(contextId: "c1", data: Data("hello".utf8))
        XCTAssertEqual(blob, AppBlob(blobId: "blob1", size: 5))
        let bytes = try await backend.getBlob(blobId: "blob1", contextId: "c1")
        XCTAssertEqual(bytes, Data("bytes".utf8))

        let members = try await backend.listMembers(groupId: "g")
        XCTAssertEqual(
            members, [AppMember(identity: me, role: "Admin", name: "Ana"), AppMember(identity: "b", role: "Member")])
        try await backend.setMemberRole(groupId: "g", identity: "b", role: .readOnly)
        try await backend.removeMember(groupId: "g", identity: "b")

        try await backend.removeContext(groupId: "g", contextId: "c2")
        try await backend.deleteSubgroup(groupId: "g")
        try await backend.leaveSubgroup(groupId: "g2")
        try await backend.leaveNamespace(namespaceId: "ns")

        XCTAssertEqual(
            admin.calls,
            [
                "listGroupContexts g", "getGroupMetadata g", "getContextMetadata g c1", "getGroupMetadata unnamed",
                // A rename keeps the record's data: setting metadata replaces it whole.
                "getGroupMetadata g", "setGroupMetadata g planning [\"icon=grid\"]",
                "getContextMetadata g c1", "setContextMetadata g c1 Q3 [\"color=red\"]",
                "getMemberMetadata g \(me)", "setMemberMetadata g \(me) Ana B [\"avatar=a1\"]",
                "uploadBlob c1 5", "getBlob blob1 c1",
                "listGroupMembers g", "updateMemberRole g b ReadOnly", "removeGroupMembers g [\"b\"]",
                "detachContextFromGroup g c2", "deleteGroup g", "leaveGroup g2", "leaveNamespace ns",
            ])
    }

    func testAnInvitationForThisAppWaitsToBeConfirmed() async {
        let session = makeSession()
        let link = "https://links.calimero.network/\(Self.package)/join?invitation=abc"
        let handled = await session.handle(URL(string: link)!)
        XCTAssertTrue(handled)
        XCTAssertEqual(session.pendingInvitation, link)

        session.dismissPendingInvitation()
        XCTAssertNil(session.pendingInvitation)
    }

    func testAnotherAppsInvitationOrAPlainLinkIsNotTaken() async {
        let session = makeSession()
        let foreign = await session.handle(
            URL(string: "https://links.calimero.network/com.calimero.chat/join?invitation=abc")!)
        let plain = await session.handle(URL(string: "board://settings")!)
        XCTAssertFalse(foreign)
        XCTAssertFalse(plain)
        XCTAssertNil(session.pendingInvitation)
    }

    func testTheInvitationParserIsPluggable() async {
        let urlSession = MockURLProtocol.makeSession()
        let client = MeroClient(
            session: urlSession,
            cloud: CloudSignIn(
                config: CloudConfig(), keyStore: .memory(), sessionStore: .memory(),
                nonces: MemoryWarrantNonceStore(), urlSession: urlSession),
            config: MeroProviderConfig(packageName: Self.package), storage: MeroAppStorage(defaults: appLayerDefaults())
        )
        let session = MeroAppSession(
            client: client, callback: .scheme("board"),
            options: MeroAppSessionOptions(isInvitation: { $0.hasPrefix("board://invite/") }))
        let custom = await session.handle(URL(string: "board://invite/xyz")!)
        let standard = await session.handle(
            URL(string: "https://links.calimero.network/\(Self.package)/join?invitation=abc")!)
        XCTAssertTrue(custom)
        XCTAssertFalse(standard, "the app's parser decides alone")
        XCTAssertEqual(session.pendingInvitation, "board://invite/xyz")
    }

    func testIsInvitationLink() {
        let pkg = Self.package
        XCTAssertTrue(
            MeroAppSession.isInvitationLink("https://links.calimero.network/\(pkg)/join?invitation=t", packageName: pkg)
        )
        XCTAssertTrue(MeroAppSession.isInvitationLink("calimero://\(pkg)/join?invitation=t", packageName: pkg))
        XCTAssertTrue(
            MeroAppSession.isInvitationLink(
                "https://links.calimero.network/COM.Example.Board/join?invitation=t", packageName: pkg),
            "a mail client may change the case")
        XCTAssertFalse(
            MeroAppSession.isInvitationLink(
                "https://links.calimero.network/\(pkg)-ar/join?invitation=t", packageName: pkg))
        XCTAssertFalse(MeroAppSession.isInvitationLink("https://links.calimero.network/\(pkg)/join", packageName: pkg))
        XCTAssertFalse(
            MeroAppSession.isInvitationLink("https://links.calimero.network/\(pkg)/join?invitation=", packageName: pkg))
        XCTAssertTrue(MeroAppSession.isInvitationLink("https://x.test/anything/join?invitation=t", packageName: nil))
    }
}
