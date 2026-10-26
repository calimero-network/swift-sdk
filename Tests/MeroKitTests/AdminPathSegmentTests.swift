import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// SEC-02: an id is exactly one path segment, whatever it holds. A `/`, `?` or
/// `#` in it is encoded rather than read as structure, and a dot segment is
/// refused before anything is sent.
final class AdminPathSegmentTests: XCTestCase {
    private var recorder: RequestRecorder!
    private var admin: AdminApi!
    private let invitation = RedeemInvitationTests.invitation

    override func setUp() {
        super.setUp()
        recorder = RequestRecorder()
        recorder.install()
        let http = URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!,
            session: MockURLProtocol.makeSession()
        )
        admin = AdminApi(http: http)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        recorder = nil
        admin = nil
        super.tearDown()
    }

    func testASlashOrQueryInAnIdCannotChangeTheRoute() async throws {
        _ = try? await admin.joinNamespace("abc/leave?x=", request: JoinNamespaceRequest(invitation: invitation))
        let join = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(join.method, "POST")
        XCTAssertEqual(join.rawPath, "/admin-api/namespaces/abc%2Fleave%3Fx%3D/join")
        XCTAssertNil(join.query)

        _ = try? await admin.getContext("../contexts/x")
        XCTAssertEqual(recorder.requests.last?.rawPath, "/admin-api/contexts/..%2Fcontexts%2Fx")

        _ = try? await admin.deleteBlob("b#frag")
        XCTAssertEqual(recorder.requests.last?.rawPath, "/admin-api/blobs/b%23frag")
    }

    func testADotSegmentIsRefusedBeforeAnythingIsSent() async {
        for bad in ["", ".", ".."] {
            do {
                _ = try await admin.joinNamespace(bad, request: JoinNamespaceRequest(invitation: invitation))
                XCTFail("\(bad) was sent")
            } catch {
                XCTAssertEqual(error as? AccountError, .invalidInput("Not a path segment: \"\(bad)\""))
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testARealIdIsSentAsIs() async {
        let ns = String(repeating: "ab", count: 32)
        _ = try? await admin.getNamespace(ns)
        XCTAssertEqual(recorder.requests.last?.rawPath, "/admin-api/namespaces/\(ns)")
    }
}
