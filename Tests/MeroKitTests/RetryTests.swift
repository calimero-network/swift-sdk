import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The transport sends every request once; retrying is the caller's opt-in
/// (``withRetry(attempts:sleep:_:)``), as in mero-js.
final class TransportRetryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> URLSessionHttpClient {
        URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!, timeout: 5, session: MockURLProtocol.makeSession())
    }

    private func serve503(counting calls: Counter) {
        MockURLProtocol.setHandler { _ in
            calls.increment()
            return .init(
                status: 503, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"busy"}"#.utf8))
        }
    }

    /// A POST that got a 503 may already have run on the node; sending it
    /// again could repeat the write. It used to go out three times.
    func testAPostThatGets503IsSentExactlyOnce() async {
        let calls = Counter()
        serve503(counting: calls)
        do {
            try await client().sendVoid(
                HttpRequest(path: "/admin-api/contexts", method: .post, body: .json(Data("{}".utf8))))
            XCTFail("expected a throw")
        } catch let error as MeroError {
            XCTAssertEqual(error.httpStatus, 503)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(calls.count, 1)
    }

    func testEveryMethodIsSentOnce() async {
        for method in [HTTPMethod.get, .put, .patch, .delete] {
            let calls = Counter()
            serve503(counting: calls)
            _ = try? await client().sendRaw(HttpRequest(path: "/x", method: method))
            XCTAssertEqual(calls.count, 1, method.rawValue)
        }
    }

    /// Through the whole SDK: an admin write that fails with a 503 is not repeated.
    func testAMeroAdminWriteIsNotRepeated() async {
        let calls = Counter()
        serve503(counting: calls)
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5),
            session: MockURLProtocol.makeSession())
        _ = try? await mero.admin.deleteContext("ctx-1")
        XCTAssertEqual(calls.count, 1)
    }
}

private func http(_ status: Int, headers: [String: String] = [:]) -> MeroError {
    .http(HTTPError(status: status, statusText: "S", url: "u", headers: headers))
}

final class WithRetryTests: XCTestCase {
    func testRetriesARetryableFailureUntilItSucceeds() async throws {
        let calls = Counter()
        let delays = DelayLog()
        let operation: @Sendable (Int) async throws -> Int = { attempt in
            if calls.increment() < 3 { throw http(503) }
            return attempt
        }
        let value = try await withRetry(attempts: 3, sleep: { delays.append($0) }, operation)
        XCTAssertEqual(value, 3)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(delays.values.count, 2)
    }

    func testDoesNotRetryARefusal() async {
        let calls = Counter()
        do {
            let operation: @Sendable (Int) async throws -> Int = { _ in
                calls.increment()
                throw http(400)
            }
            _ = try await withRetry(attempts: 3, sleep: { _ in }, operation)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? MeroError)?.httpStatus, 400)
        }
        XCTAssertEqual(calls.count, 1)
    }

    func testGivesUpAfterTheLastAttempt() async {
        let calls = Counter()
        let operation: @Sendable (Int) async throws -> Int = { _ in
            calls.increment()
            throw MeroError.network("offline")
        }
        _ = try? await withRetry(attempts: 2, sleep: { _ in }, operation)
        XCTAssertEqual(calls.count, 2)
    }

    func testHonoursRetryAfter() async throws {
        let calls = Counter()
        let delays = DelayLog()
        let operation: @Sendable (Int) async throws -> Int = { _ in
            if calls.increment() == 1 { throw http(429, headers: ["retry-after": "7"]) }
            return 0
        }
        _ = try await withRetry(attempts: 2, sleep: { delays.append($0) }, operation)
        XCTAssertEqual(delays.values, [7])
    }

    func testRetryAfterReadsAnHTTPDateCappedAtAMinute() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // Tue, 14 Nov 2023 22:13:20 GMT
        let soon = http(503, headers: ["retry-after": "Tue, 14 Nov 2023 22:13:30 GMT"])
        XCTAssertEqual(retryAfter(soon, now: now) ?? -1, 10, accuracy: 0.5)
        let late = http(503, headers: ["retry-after": "Wed, 15 Nov 2023 22:13:20 GMT"])
        XCTAssertEqual(retryAfter(late, now: now), 60)
        XCTAssertNil(retryAfter(http(503), now: now))
    }
}

/// A thread-safe log of the delays `withRetry` asked to sleep.
final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }
}
