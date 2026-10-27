import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// SEC-08: a response body and an SSE line are read up to a limit, and a
/// larger one is refused rather than buffered.
final class ResponseLimitTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client(limit: Int) -> URLSessionHttpClient {
        URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession(),
            maxResponseBytes: limit)
    }

    private func serve(_ body: Data, headers: [String: String] = [:]) {
        MockURLProtocol.setHandler { _ in .init(status: 200, headers: headers, body: body) }
    }

    private func assertTooLarge(
        _ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    )
        async
    {
        do {
            try await work()
            XCTFail("expected the body to be refused", file: file, line: line)
        } catch MeroError.network(let message) {
            XCTAssertTrue(message.contains("exceeds"), message, file: file, line: line)
        } catch {
            XCTFail("expected MeroError.network, got \(error)", file: file, line: line)
        }
    }

    // MARK: - HTTP bodies

    func testTheDefaultLimitIsSixteenMebibytes() {
        XCTAssertEqual(URLSessionHttpClient.defaultMaxResponseBytes, 16 * 1024 * 1024)
        XCTAssertEqual(
            MeroConfig(baseURL: URL(string: "https://node.test")!).maxResponseBytes,
            URLSessionHttpClient.defaultMaxResponseBytes)
    }

    func testABodyAtTheLimitIsRead() async throws {
        serve(Data(repeating: 0x61, count: 1024))
        let (data, head) = try await client(limit: 1024).sendRaw(HttpRequest(path: "/x"))
        XCTAssertEqual(data.count, 1024)
        XCTAssertEqual(head.status, 200)
    }

    func testABodyOverTheLimitIsRefused() async {
        serve(Data(repeating: 0x61, count: 1025))
        await assertTooLarge { _ = try await self.client(limit: 1024).sendRaw(HttpRequest(path: "/x")) }
    }

    func testAContentLengthOverTheLimitIsRefusedBeforeTheBodyIsRead() async {
        serve(Data(repeating: 0x61, count: 2048), headers: ["Content-Length": "2048"])
        await assertTooLarge { _ = try await self.client(limit: 1024).sendRaw(HttpRequest(path: "/x")) }
    }

    func testAnErrorBodyIsHeldToTheLimitToo() async {
        MockURLProtocol.setHandler { _ in .init(status: 500, headers: [:], body: Data(repeating: 0x61, count: 4096)) }
        await assertTooLarge { _ = try await self.client(limit: 1024).sendRaw(HttpRequest(path: "/x")) }
    }

    func testMeroConfigSetsTheLimitAndABlobIsNotHeldToIt() async throws {
        let blob = Data(repeating: 0x7f, count: 4096)
        MockURLProtocol.setHandler { request in
            if request.url?.path == "/admin-api/blobs/b1" {
                return .init(status: 200, headers: ["Content-Length": "4096"], body: blob)
            }
            return .init(status: 200, headers: [:], body: Data(#"{"data":{"blobs":[]}}"#.utf8) + Data(count: 4096))
        }
        let config = MeroConfig(baseURL: URL(string: "https://node.test")!, maxResponseBytes: 1024)
        let mero = Mero(config: config, session: MockURLProtocol.makeSession())

        let downloaded = try await mero.admin.getBlob("b1")
        XCTAssertEqual(downloaded, blob, "a blob download is not limited")
        await assertTooLarge { _ = try await mero.admin.listBlobs() }
    }

    // MARK: - SSE lines

    private func lines(_ text: String, limit: Int) async throws -> [String] {
        var out: [String] = []
        for try await line in SseLines(ByteStream(Array(text.utf8)), limit: limit) { out.append(line) }
        return out
    }

    func testSplitsLinesOnLFCRLFAndCR() async throws {
        let read = try await lines("data: a\nid: 1\r\n\rdata: b\r\n\ndata: c", limit: 64)
        XCTAssertEqual(read, ["data: a", "id: 1", "", "data: b", "", "data: c"])
    }

    func testALineAtTheLimitIsRead() async throws {
        let line = "data:" + String(repeating: "x", count: 59)
        let read = try await lines(line + "\n", limit: 64)
        XCTAssertEqual(read, [line])
    }

    func testALineOverTheLimitDropsTheStream() async {
        let line = "data:" + String(repeating: "x", count: 60)
        await assertTooLarge { _ = try await self.lines(line + "\n", limit: 64) }
        await assertTooLarge { _ = try await self.lines(":" + String(repeating: "x", count: 64), limit: 64) }
    }

    func testAnEventOverTheLimitDropsTheStreamEvenInShortLines() async {
        let short = "data:" + String(repeating: "x", count: 20) + "\n"
        await assertTooLarge { _ = try await self.lines(String(repeating: short, count: 4), limit: 64) }
    }

    func testABlankLineEndsTheEventAndCommentsDoNotCount() async throws {
        let short = "data:" + String(repeating: "x", count: 20) + "\n"
        let keepAlive = ":" + String(repeating: "k", count: 40) + "\n"
        let stream = String(repeating: short + short + keepAlive + "\n", count: 10)
        let read = try await lines(stream, limit: 64)
        XCTAssertEqual(read.count, 40)
    }

    func testTheConnectionLimitIsOneMebibyte() {
        XCTAssertEqual(SseConnection.maxLineBytes, 1024 * 1024)
    }
}

/// Bytes as an `AsyncSequence`, the shape `URLSession.AsyncBytes` has.
private struct ByteStream: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    struct AsyncIterator: AsyncIteratorProtocol {
        var inner: IndexingIterator<[UInt8]>
        mutating func next() async -> UInt8? { inner.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(inner: bytes.makeIterator()) }
}
