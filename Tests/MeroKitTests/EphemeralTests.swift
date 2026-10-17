import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Ephemeral presence (port of mero-js `ephemeral.test.ts`).
final class EphemeralTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func mero() async -> Mero {
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5),
            session: MockURLProtocol.makeSession())
        await mero.setTokenData(
            TokenData(accessToken: "T", refreshToken: "R", expiresAt: Date().addingTimeInterval(3600)))
        return mero
    }

    func testJSONCodecRoundTripsThroughBytes() throws {
        let codec = JSONCodec<Point>()
        let bytes = try codec.encode(Point(x: 7))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"x":7}"#)
        XCTAssertEqual(try codec.decode(bytes), Point(x: 7))
    }

    // MARK: - set

    func testSetPostsSetEphemeralWithTheEncodedStateAndNoAuthor() async throws {
        let bodies = SyncLog<[String: Any]>()
        MockURLProtocol.setHandler { req in
            if let body = try? JSONSerialization.jsonObject(with: FakeNode.body(req)) as? [String: Any] {
                bodies.append(body)
            }
            return .init(status: 200, headers: [:], body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        }
        let sdk = await mero()
        try await sdk.ephemeral.set(contextId: "ctx-1", state: Point(x: 1))

        let body = try XCTUnwrap(bodies.values.first)
        XCTAssertEqual(body["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(body["method"] as? String, "set_ephemeral")
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["contextId", "state"], "the author is resolved server-side")
        XCTAssertEqual(params["contextId"] as? String, "ctx-1")
        XCTAssertEqual(params["state"] as? [Int], Array(#"{"x":1}"#.utf8).map { Int($0) }, "a byte array, not text")
    }

    func testSetThrowsATypedRpcErrorWithTheServersTypeAndData() async {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: [:],
                body: Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"type":"SliceTooLarge","data":{"size":20000,"max":16384}}}"#
                        .utf8))
        }
        let sdk = await mero()
        do {
            try await sdk.ephemeral.set(contextId: "ctx-1", state: Point(x: 1))
            XCTFail("expected a throw")
        } catch MeroError.rpc(let rpc) {
            XCTAssertEqual(rpc.type, "SliceTooLarge")
            XCTAssertEqual(rpc.message, "SliceTooLarge")
            XCTAssertEqual(rpc.data?["max"]?.intValue, 16384)
        } catch {
            XCTFail("expected MeroError.rpc, got \(error)")
        }
    }

    func testSetThrowsOnAPlainRpcError() async {
        MockURLProtocol.setHandler { _ in
            .init(
                status: 200, headers: [:],
                body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nope"}}"#.utf8))
        }
        let sdk = await mero()
        do {
            try await sdk.ephemeral.set(contextId: "ctx-1", state: Point(x: 1))
            XCTFail("expected a throw")
        } catch MeroError.rpc(let rpc) {
            XCTAssertEqual(rpc.message, "nope")
            XCTAssertEqual(rpc.code, -32000)
        } catch {
            XCTFail("expected MeroError.rpc, got \(error)")
        }
    }

    // MARK: - subscribe

    func testEntryDecoding() throws {
        let codec = JSONCodec<Point>()
        let state = JSONValue.array(Array(#"{"x":1}"#.utf8).map { .number(Double($0)) })
        let upsert = EphemeralEntry<Point>.decode(["author": "A", "state": state], codec: codec)
        XCTAssertEqual(upsert, EphemeralEntry(author: "A", state: Point(x: 1), removed: false))
        XCTAssertNil(upsert?.ageMs, "a live delta has no ageMs, not 0")

        let removal = EphemeralEntry<Point>.decode(["author": "A", "removed": true], codec: codec)
        XCTAssertEqual(removal, EphemeralEntry(author: "A", state: nil, removed: true), "no state to decode")

        let replayed = EphemeralEntry<Point>.decode(
            ["author": "A", "state": state, "ageMs": 447, "account": "acct"], codec: codec)
        XCTAssertEqual(replayed?.ageMs, 447)
        XCTAssertEqual(replayed?.account, "acct")

        XCTAssertNil(EphemeralEntry<Point>.decode(["state": state], codec: codec), "no author")
        XCTAssertNil(
            EphemeralEntry<Point>.decode(["author": "A", "state": [1, 2]], codec: codec), "state that does not decode")
    }

    func testSubscribeDeliversOnlyThisContextsEphemeralEventsAndSubscribesIt() async throws {
        let one = Frames.bytes(#"{"x":1}"#)
        let frames =
            Frames.connect("s1")
            + Frames.result(#"{"contextId":"ctx-1","type":"AppVersionChanged","data":{}}"#)
            + Frames.ephemeral("ctx-2", #"{"author":"A","state":\#(one)}"#)
            + Frames.ephemeral("ctx-1", #"{"author":"A","state":\#(one)}"#)
            + Frames.ephemeral("ctx-1", #"{"author":"A","removed":true}"#)
        let node = ScriptedNode(streams: [ScriptedNode.open(frames)])
        node.install()
        let sdk = await mero()
        let ephemeral = await sdk.ephemeral
        defer { ephemeral.events.close() }

        let seen = SyncLog<EphemeralEntry<Point>>()
        let task = Task {
            for try await entry in ephemeral.subscribe(contextId: "ctx-1", as: Point.self) {
                seen.append(entry)
            }
        }
        _ = await eventually { seen.values.count == 2 }
        XCTAssertEqual(
            seen.values,
            [
                EphemeralEntry(author: "A", state: Point(x: 1), removed: false),
                EphemeralEntry(author: "A", state: nil, removed: true),
            ])
        XCTAssertTrue(ephemeral.events.isSubscribed("ctx-1"), "subscribing presence subscribes the context")
        XCTAssertTrue(ephemeral.events === sdk.sse, "presence shares the instance's one connection")
        task.cancel()
    }

    func testCloseEndsPresenceStreams() async throws {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))])
        node.install()
        let sdk = await mero()
        let ephemeral = await sdk.ephemeral
        let ended = SyncLog<Bool>()
        let task = Task {
            for try await _ in ephemeral.subscribe(contextId: "ctx-1", as: Point.self) {}
            ended.append(true)
        }
        _ = await eventually { sdk.sse.sessionId == "s1" }
        await sdk.close()
        let finished = await eventually { ended.values == [true] }
        XCTAssertTrue(finished)
        task.cancel()
    }
}
