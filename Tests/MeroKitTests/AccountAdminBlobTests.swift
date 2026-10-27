import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// An account's blobs go to its relay, always through a context: core gives an
/// account session `blob:add-own` / `blob:get-own`, checked per context.
final class AccountAdminBlobTests: XCTestCase {
    private let ctx = DelegatedFixture.rep("03")
    private let blob = DelegatedFixture.rep("ab")
    private var rig: CloudRig!

    override func setUp() {
        super.setUp()
        rig = CloudRig()
        rig.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        rig = nil
        super.tearDown()
    }

    private func admin(relay: Bool = true) -> AccountAdmin {
        let read = AdminApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: DelegatedFixture.relay)!, session: MockURLProtocol.makeSession()))
        let session = DelegatedFixture.session()
        return AccountAdmin(
            session: relay ? session : session.on(relay: nil), read: relay ? read : nil,
            env: DelegatedFixture.environment())
    }

    func testAnUploadStreamsTheBytesToTheRelayAgainstItsContext() async throws {
        rig.on("PUT", "/admin-api/blobs", json: #"{"data":{"blob_id":"\#(blob)","size":3}}"#)
        let surface: any AdminSurface = admin()
        let info = try await surface.uploadBlob(UploadBlobRequest(data: Data([1, 2, 3]), contextId: ctx))
        XCTAssertEqual(info.blobId, blob)
        XCTAssertEqual(info.size, 3)
        let sent = try XCTUnwrap(rig.requests("PUT", "/admin-api/blobs").first)
        XCTAssertEqual(sent.url.host, "relay.test")
        XCTAssertEqual(sent.url.query, "context_id=\(ctx)")
        XCTAssertEqual(sent.headers["content-type"], "application/octet-stream")
        XCTAssertEqual(sent.body, Data([1, 2, 3]))
    }

    func testADownloadReadsThroughTheContextAndReturnsTheRawBytes() async throws {
        rig.on("GET", "/admin-api/blobs/\(blob)") { _ in
            .init(status: 200, headers: ["Content-Type": "image/png"], body: Data([9, 8, 7]))
        }
        let surface: any AdminSurface = admin()
        let bytes = try await surface.getBlob(blob, contextId: ctx)
        XCTAssertEqual(bytes, Data([9, 8, 7]))
        XCTAssertEqual(rig.requests("GET", "/admin-api/blobs/\(blob)").first?.url.query, "context_id=\(ctx)")
    }

    func testInfoIsAHeadThroughTheContext() async throws {
        rig.on("HEAD", "/admin-api/blobs/\(blob)") { _ in
            .init(
                status: 200,
                headers: ["Content-Length": "42", "x-blob-mime-type": "image/png", "x-blob-source": "local"],
                body: Data())
        }
        let info = try await admin().getBlobInfo(blob, contextId: ctx)
        XCTAssertEqual(info.mimeType, "image/png")
        XCTAssertEqual(rig.requests("HEAD", "/admin-api/blobs/\(blob)").first?.url.query, "context_id=\(ctx)")
    }

    func testEveryBlobCallNamesAContextAndSendsNothingWithoutOne() async {
        let admin = admin()
        for call in [
            { _ = try await admin.uploadBlob(UploadBlobRequest(data: Data([1]))) },
            { _ = try await admin.getBlob(self.blob, contextId: nil) },
            { _ = try await admin.getBlobInfo(self.blob, contextId: "") },
        ] as [() async throws -> Void] {
            do {
                try await call()
                XCTFail("a blob call with no context must be refused")
            } catch AccountError.invalidInput(let reason) {
                XCTAssertTrue(reason.contains("contextId"), reason)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testWithNoRelayAnUploadSaysSoAndTheListIsEmpty() async throws {
        let admin = admin(relay: false)
        do {
            _ = try await admin.uploadBlob(UploadBlobRequest(data: Data([1]), contextId: ctx))
            XCTFail("no relay, no upload")
        } catch {
            XCTAssertEqual(error as? AccountError, .noRelay(method: "uploadBlob"))
        }
        let listed = try await admin.listBlobs()
        XCTAssertTrue(listed.blobs.isEmpty)
    }

    func testAListIsTheRelaysCallerScopedOne() async throws {
        rig.on("GET", "/admin-api/blobs", json: #"{"data":{"blobs":[{"blob_id":"\#(blob)","size":5}]}}"#)
        let listed = try await admin().listBlobs()
        XCTAssertEqual(listed.blobs.map(\.blobId), [blob])
    }
}
