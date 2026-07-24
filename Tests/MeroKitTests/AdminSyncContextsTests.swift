import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// `AdminApi.syncGroupContexts` should sync the group, list its contexts, and
/// join + state-pull each one — the anti-"1111…" (uninitialized context) flow
/// the SDK now offers so clients joining a namespace/group don't have to
/// reimplement it and hit the trap.
final class AdminSyncContextsTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func note(_ value: String) {
            lock.lock()
            items.append(value)
            lock.unlock()
        }
        var seen: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    func testSyncGroupContextsJoinsAndSyncsEachContext() async throws {
        let recorder = Recorder()
        MockURLProtocol.setHandler { req in
            let method = req.httpMethod ?? "GET"
            let path = req.url?.path ?? ""
            recorder.note("\(method) \(path)")
            let body: Data =
                (method == "GET" && path == "/admin-api/groups/g1/contexts")
                ? Data(#"{"data":[{"contextId":"c1"},{"contextId":"c2"}]}"#.utf8)
                : Data("{}".utf8)
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }
        defer { MockURLProtocol.reset() }

        let admin = AdminApi(
            http: URLSessionHttpClient(
                baseURL: URL(string: "https://node.test")!,
                session: MockURLProtocol.makeSession()))

        let contexts = try await admin.syncGroupContexts("g1")

        // It returns the group's contexts…
        XCTAssertEqual(contexts.map(\.contextId), ["c1", "c2"])
        // …and issued: group sync, list, then join + per-context sync for each.
        let seen = recorder.seen
        XCTAssertTrue(seen.contains("POST /admin-api/groups/g1/sync"), "seen=\(seen)")
        XCTAssertTrue(seen.contains("GET /admin-api/groups/g1/contexts"), "seen=\(seen)")
        for ctx in ["c1", "c2"] {
            XCTAssertTrue(seen.contains("POST /admin-api/contexts/\(ctx)/join"), "join \(ctx); seen=\(seen)")
            XCTAssertTrue(seen.contains("POST /admin-api/contexts/sync/\(ctx)"), "sync \(ctx); seen=\(seen)")
        }
    }
}
