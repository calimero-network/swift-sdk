import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A blob is bytes, and every byte value has to survive the trip.
///
/// The Kotlin SDK once corrupted blobs by passing their bytes through a text
/// encoding: every byte at or above `0x80` came back changed. Swift keeps blob
/// bodies as `Data` end to end, and this pins that: all 256 byte values go out
/// on the wire as sent, and come back as served.
final class BlobBytesTests: XCTestCase {
    private static let everyByte = Data((0...255).map { UInt8($0) })

    private var admin: AdminApi!

    override func setUp() {
        super.setUp()
        admin = AdminApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!,
                session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        admin = nil
        super.tearDown()
    }

    func testUploadSendsEveryByteValueVerbatim() async throws {
        let wire = WireCapture()
        MockURLProtocol.setHandler { req in
            wire.record(body: FakeNode.body(req), contentType: req.value(forHTTPHeaderField: "Content-Type"))
            return .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"data":{"blob_id":"b1","size":256}}"#.utf8))
        }

        let info = try await admin.uploadBlob(UploadBlobRequest(data: Self.everyByte))

        XCTAssertEqual(info.blobId, "b1")
        XCTAssertEqual(wire.body, Self.everyByte, "the body on the wire is the blob, byte for byte")
        XCTAssertEqual(wire.body?.count, 256)
        XCTAssertEqual(wire.contentType, "application/octet-stream")
    }

    func testGetBlobReturnsEveryByteValueAsServed() async throws {
        MockURLProtocol.setHandler { _ in
            .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Self.everyByte)
        }

        let bytes = try await admin.getBlob("b1")

        XCTAssertEqual(bytes, Self.everyByte)
    }

    /// The same round trip through ``FakeNode``'s blob store.
    func testEveryByteValueRoundTripsThroughFakeNode() async throws {
        let node = FakeNode()
        node.install()
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5, tokenStore: MemoryTokenStore()),
            session: MockURLProtocol.makeSession())
        _ = try await mero.authenticate(Credentials(username: "dev", password: "pw"))

        let info = try await mero.admin.uploadBlob(UploadBlobRequest(data: Self.everyByte))
        XCTAssertEqual(info.size, 256)
        XCTAssertEqual(node.blob(info.blobId), Self.everyByte, "stored as received")
        let back = try await mero.admin.getBlob(info.blobId)
        XCTAssertEqual(back, Self.everyByte)
    }
}

private final class WireCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _body: Data?
    private var _contentType: String?

    func record(body: Data, contentType: String?) {
        lock.lock(); _body = body; _contentType = contentType; lock.unlock()
    }

    var body: Data? {
        lock.lock(); defer { lock.unlock() }
        return _body
    }

    var contentType: String? {
        lock.lock(); defer { lock.unlock() }
        return _contentType
    }
}
