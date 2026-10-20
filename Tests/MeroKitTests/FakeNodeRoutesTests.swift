import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The routes ``FakeNode`` serves beyond auth and JSON-RPC, driven through the
/// SDK's own clients, so a shape the SDK cannot decode fails here first, and
/// ``MockURLProtocol``'s transport errors.
final class FakeNodeRoutesTests: XCTestCase {
    private var node: FakeNode!
    private var mero: Mero!

    override func setUp() async throws {
        try await super.setUp()
        node = FakeNode()
        node.install()
        mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5, tokenStore: MemoryTokenStore()),
            session: MockURLProtocol.makeSession())
        _ = try await mero.authenticate(Credentials(username: "dev", password: "pw"))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        node = nil
        mero = nil
        super.tearDown()
    }

    // MARK: - Client keys

    func testAMintedClientKeyIsRecordedAndAccepted() async throws {
        let auth = await mero.auth
        let minted = try await auth.generateClientKey(
            GenerateClientKeyRequest(contextId: "ctx-1", permissions: ["context:execute"], applicationId: "app-1"))

        XCTAssertFalse(minted.data.accessToken.isEmpty)
        XCTAssertFalse(minted.data.refreshToken.isEmpty)
        let key = try XCTUnwrap(node.clientKeys.first)
        XCTAssertEqual(key.contextId, "ctx-1")
        XCTAssertEqual(key.applicationId, "app-1")
        XCTAssertEqual(key.permissions, ["context:execute"])
        XCTAssertEqual(key.accessToken, minted.data.accessToken)

        let validation = await auth.validateToken(minted.data.accessToken)
        XCTAssertTrue(validation.valid, "the node accepts the key it minted")
    }

    func testMintingAClientKeyNeedsASession() async throws {
        node.revokeFamily()
        let auth = await mero.auth
        do {
            _ = try await auth.generateClientKey(GenerateClientKeyRequest(permissions: ["admin"]))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(node.clientKeys.isEmpty)
        }
    }

    // MARK: - Contexts

    func testContextsAreCreatedListedReadAndDeleted() async throws {
        let admin = await mero.admin
        let empty = try await admin.getContexts()
        XCTAssertEqual(empty.contexts.count, 0, "a new node holds no contexts")

        let created = try await admin.createContext(CreateContextRequest(applicationId: "app-1", groupId: "g-1"))
        XCTAssertEqual(created.groupId, "g-1")
        XCTAssertFalse(created.memberPublicKey.isEmpty)

        let listed = try await admin.getContexts()
        XCTAssertEqual(listed.contexts.map(\.id), [created.contextId])
        XCTAssertEqual(listed.contexts.first?.applicationId, "app-1")
        XCTAssertEqual(listed.contexts.first?.groupId, "g-1")

        let context = try await admin.getContext(created.contextId)
        XCTAssertEqual(context.applicationId, "app-1")

        let deleted = try await admin.deleteContext(created.contextId)
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertEqual(node.contextIds, [])
    }

    func testASeededContextIsListedForItsApplication() async throws {
        node.addContext(id: "c-a", applicationId: "app-a")
        node.addContext(id: "c-b", applicationId: "app-b")
        let admin = await mero.admin

        let forA = try await admin.getContextsForApplication("app-a")
        XCTAssertEqual(forA.contexts.map(\.id), ["c-a"])
    }

    func testAnUnknownContextIsA404() async throws {
        let admin = await mero.admin
        do {
            _ = try await admin.getContext("missing")
            XCTFail("expected a 404")
        } catch let error as MeroError {
            XCTAssertEqual(error.httpStatus, 404)
        }
    }

    // MARK: - Applications

    func testSeededApplicationsAreListedAndRead() async throws {
        node.addApplication(id: "app-1", package: "com.example.notes", version: "2.1.0")
        let admin = await mero.admin

        let apps = try await admin.listApplications().apps
        XCTAssertEqual(apps.map(\.id), ["app-1"])
        XCTAssertEqual(apps.first?.package, "com.example.notes")
        XCTAssertEqual(apps.first?.version, "2.1.0")

        let one = try await admin.getApplication("app-1")
        XCTAssertEqual(one.application?.package, "com.example.notes")
        let none = try await admin.getApplication("nope")
        XCTAssertNil(none.application)
    }

    // MARK: - Blobs

    func testBlobsAreUploadedListedInspectedAndDeleted() async throws {
        let admin = await mero.admin
        let bytes = Data("hello".utf8)

        let info = try await admin.uploadBlob(UploadBlobRequest(data: bytes))
        XCTAssertEqual(info.size, 5)
        let listed = try await admin.listBlobs()
        XCTAssertEqual(listed.blobs.map(\.blobId), [info.blobId])
        let downloaded = try await admin.getBlob(info.blobId)
        XCTAssertEqual(downloaded, bytes)

        let head = try await admin.getBlobInfo(info.blobId)
        XCTAssertEqual(head.size, 5)
        XCTAssertEqual(head.source, .local)

        let deleted = try await admin.deleteBlob(info.blobId)
        XCTAssertTrue(deleted.deleted)
        XCTAssertNil(node.blob(info.blobId))
        do {
            _ = try await admin.getBlob(info.blobId)
            XCTFail("expected a 404")
        } catch let error as MeroError {
            XCTAssertEqual(error.httpStatus, 404)
        }
    }

    func testASeededBlobIsServed() async throws {
        let id = node.putBlob(Data([1, 2, 3]))
        let admin = await mero.admin
        let bytes = try await admin.getBlob(id)
        XCTAssertEqual(bytes, Data([1, 2, 3]))
    }

    // MARK: - Metadata

    func testMetadataIsNilUntilSetAndKeepsItsNameAcrossUpdates() async throws {
        let admin = await mero.admin
        let before = try await admin.getGroupMetadata("g-1")
        XCTAssertNil(before)

        try await admin.setGroupMetadata("g-1", request: SetMetadataRequest(name: "Team", data: ["k": "v"]))
        try await admin.setGroupMetadata("g-1", request: SetMetadataRequest(data: ["k": "w"]))
        let fetched = try await admin.getGroupMetadata("g-1")
        let group = try XCTUnwrap(fetched)
        XCTAssertEqual(group.name, "Team", "an omitted name keeps the current one")
        XCTAssertEqual(group.data, ["k": "w"])

        try await admin.setContextMetadata("g-1", contextId: "c-1", request: SetMetadataRequest(name: "Room"))
        let context = try await admin.getContextMetadata("g-1", contextId: "c-1")
        XCTAssertEqual(context?.name, "Room")
        try await admin.setMemberMetadata("g-1", identity: "m-1", request: SetMetadataRequest(name: "Ana"))
        let member = try await admin.getMemberMetadata("g-1", identity: "m-1")
        XCTAssertEqual(member?.name, "Ana")
        let groupAgain = try await admin.getGroupMetadata("g-1")
        XCTAssertEqual(groupAgain?.name, "Team", "each target has its own record")
    }

    // MARK: - Transport errors

    func testAnOfflineNodeFailsAtTheTransport() async throws {
        node.goOffline()
        let admin = await mero.admin
        do {
            _ = try await admin.getContexts()
            XCTFail("expected a transport error")
        } catch MeroError.network {
            // No HTTP response at all: not a status, not a refusal.
        }

        node.goOnline()
        let contexts = try await admin.getContexts()
        XCTAssertEqual(contexts.contexts.count, 0)
    }

    func testATransportErrorStubSurfacesAsANetworkError() async {
        MockURLProtocol.setHandler { _ in .transportError(.timedOut) }
        let http = URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession())
        do {
            _ = try await http.sendRaw(HttpRequest(path: "/admin-api/contexts"))
            XCTFail("expected a transport error")
        } catch MeroError.network {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testADelayedTransportErrorStillFails() async {
        MockURLProtocol.setHandler { _ in .transportError(.networkConnectionLost, delay: 0.05) }
        let http = URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession())
        do {
            _ = try await http.sendRaw(HttpRequest(path: "/x"))
            XCTFail("expected a transport error")
        } catch MeroError.network {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
