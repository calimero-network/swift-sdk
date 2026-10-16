import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A socket a test drives: inbound messages are pushed, sends are recorded.
final class FakeWebSocket: WebSocketTransport, @unchecked Sendable {
    let sent = SyncLog<String>()
    private let lock = NSLock()
    private var inbox: [WebSocketMessage] = []
    private var waiting: CheckedContinuation<WebSocketMessage, Error>?
    private var closed = false

    func push(_ text: String) {
        deliver(.success(.text(text)))
    }

    /// The server closes the socket.
    func drop() {
        deliver(.failure(URLError(.networkConnectionLost)))
    }

    private func deliver(_ result: Result<WebSocketMessage, Error>) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(with: result)
            return
        }
        if case .success(let message) = result { inbox.append(message) } else { closed = true }
        lock.unlock()
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func receive() async throws -> WebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let message = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let pending = waiting
        waiting = nil
        lock.unlock()
        pending?.resume(throwing: URLError(.cancelled))
    }
}

/// Hands out a fresh ``FakeWebSocket`` per connect, recording the upgrade requests.
final class FakeConnector: WebSocketConnector, @unchecked Sendable {
    let requests = SyncLog<URLRequest>()
    let sockets = SyncLog<FakeWebSocket>()

    func open(_ request: URLRequest) async throws -> any WebSocketTransport {
        requests.append(request)
        let socket = FakeWebSocket()
        sockets.append(socket)
        return socket
    }
}

/// Port of mero-js `ws.test.ts`, plus the reconnect behaviour.
final class WsClientTests: XCTestCase {
    private func client(
        _ connector: FakeConnector, delays: SyncLog<TimeInterval> = SyncLog(), base: String = "https://node.test/",
        tokenInQuery: Bool = false
    ) -> WsClient {
        WsClient(
            baseURL: URL(string: base)!, token: { "a b/c" }, connector: connector, backoff: .webSocket,
            tokenInQuery: tokenInQuery,
            sleep: { delay in
                delays.append(delay)
                try? await Task.sleep(nanoseconds: 5_000_000)
            })
    }

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func testSocketRequestCarriesTheTokenInTheAuthorizationHeader() {
        let request = WsClient.socketRequest(
            baseURL: URL(string: "https://node.test/base/")!, token: "a b/c+d=", tokenInQuery: false)
        XCTAssertEqual(request?.url?.absoluteString, "wss://node.test/base/ws", "no token in the URL")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer a b/c+d=")
        let local = WsClient.socketRequest(
            baseURL: URL(string: "http://localhost:2428")!, token: "t", tokenInQuery: false)
        XCTAssertEqual(local?.url?.absoluteString, "ws://localhost:2428/ws")
    }

    func testTokenInQueryCarriesTheTokenAsEncodeURIComponentDoes() {
        let request = WsClient.socketRequest(
            baseURL: URL(string: "https://node.test/base/")!, token: "a b/c+d=", tokenInQuery: true)
        XCTAssertEqual(request?.url?.absoluteString, "wss://node.test/base/ws?token=a%20b%2Fc%2Bd%3D")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"), "the query replaces the header")
        let local = WsClient.socketRequest(
            baseURL: URL(string: "http://localhost:2428")!, token: "t", tokenInQuery: true)
        XCTAssertEqual(local?.url?.absoluteString, "ws://localhost:2428/ws?token=t")
    }

    func testSubscriptionMessagesMatchCoresShape() {
        XCTAssertEqual(
            WsClient.message("subscribe", contextIds: ["c1"], groupIds: ["g1"]),
            #"{"id":null,"method":"subscribe","params":{"contextIds":["c1"],"groupIds":["g1"]}}"#)
        XCTAssertEqual(
            WsClient.message("unsubscribe", contextIds: [], groupIds: ["g1"]),
            #"{"id":null,"method":"unsubscribe","params":{"groupIds":["g1"]}}"#, "an empty list is left out")
    }

    func testConnectsSubscribesAndDeliversEvents() async throws {
        let connector = FakeConnector()
        let ws = client(connector)
        let events = SyncLog<NodeEvent>()
        let connects = Counter()
        let task = Task {
            for try await event in ws.updates() {
                switch event {
                case .connect: connects.increment()
                case .event(let nodeEvent): events.append(nodeEvent)
                case .error: break
                }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await ws.subscribe(contextIds: ["c1"])
        ws.connect()
        defer { ws.close() }
        _ = await eventually { connector.sockets.values.count == 1 && connects.count == 1 }
        let upgrade = connector.requests.values.first
        XCTAssertEqual(upgrade?.url?.absoluteString, "wss://node.test/ws")
        XCTAssertEqual(upgrade?.value(forHTTPHeaderField: "Authorization"), "Bearer a b/c")
        let socket = try XCTUnwrap(connector.sockets.values.first)
        _ = await eventually { socket.sent.values.count == 1 }
        XCTAssertEqual(json(socket.sent.values[0])["method"] as? String, "subscribe", "remembered ids, sent on open")

        await ws.subscribe(groupIds: ["g1"])
        XCTAssertEqual(socket.sent.values.last, #"{"id":null,"method":"subscribe","params":{"groupIds":["g1"]}}"#)

        socket.push(#"{"id":null,"result":{"contextId":"c1","type":"AppVersionChanged","data":{"toVersion":"2"}}}"#)
        socket.push(#"{"result":{"groupId":"g1","type":"MemberJoined","data":{"memberAccount":"a"}}}"#)
        socket.push(#"{"id":7,"result":{"contextIds":["c1"]}}"#)  // a subscribe response, not an event
        socket.push("not json")
        _ = await eventually { events.values.count == 2 }
        guard events.values.count == 2, case .context(let context) = events.values[0],
            case .group(let group) = events.values[1]
        else { return XCTFail("\(events.values)") }
        XCTAssertEqual(context.kind, "AppVersionChanged", "the type tag is forwarded")
        XCTAssertEqual(context.appVersionChanged?.toVersion, "2")
        XCTAssertEqual(group.membership?.memberAccount, "a")

        await ws.unsubscribe(contextIds: ["c1"])
        XCTAssertEqual(
            socket.sent.values.last, #"{"id":null,"method":"unsubscribe","params":{"contextIds":["c1"]}}"#)
        XCTAssertEqual(ws.subscribedContextIds, [])
        task.cancel()
    }

    func testReconnectsWithBackoffAndReSubscribesBothKindsOfIds() async throws {
        let connector = FakeConnector()
        let delays = SyncLog<TimeInterval>()
        let ws = client(connector, delays: delays)
        await ws.subscribe(contextIds: ["c1"], groupIds: ["g1"])
        ws.connect()
        defer { ws.close() }
        _ = await eventually { connector.sockets.values.count == 1 }
        connector.sockets.values[0].drop()
        _ = await eventually { connector.sockets.values.count == 2 }
        let second = connector.sockets.values[1]
        _ = await eventually { !second.sent.values.isEmpty }
        XCTAssertEqual(
            second.sent.values.first,
            #"{"id":null,"method":"subscribe","params":{"contextIds":["c1"],"groupIds":["g1"]}}"#)
        XCTAssertEqual(delays.values, [1], "an open socket resets the backoff, so a drop waits 1 s")
    }

    func testTokenInQueryConnectsWithTheTokenInTheURL() async {
        let connector = FakeConnector()
        let ws = client(connector, tokenInQuery: true)
        XCTAssertTrue(ws.tokenInQuery)
        ws.connect()
        defer { ws.close() }
        _ = await eventually { connector.requests.values.count == 1 }
        let upgrade = connector.requests.values.first
        XCTAssertEqual(upgrade?.url?.absoluteString, "wss://node.test/ws?token=a%20b%2Fc")
        XCTAssertNil(upgrade?.value(forHTTPHeaderField: "Authorization"))
    }

    func testBackoffGrowsWhileConnectsFail() async {
        final class Refusing: WebSocketConnector, @unchecked Sendable {
            let attempts = Counter()
            func open(_ request: URLRequest) async throws -> any WebSocketTransport {
                attempts.increment()
                throw URLError(.cannotConnectToHost)
            }
        }
        let connector = Refusing()
        let delays = SyncLog<TimeInterval>()
        let ws = WsClient(
            baseURL: URL(string: "http://node.test")!, token: { "t" }, connector: connector, backoff: .webSocket,
            sleep: { delay in
                delays.append(delay)
                try? await Task.sleep(nanoseconds: 1_000_000)
            })
        let errors = Counter()
        let off = Task {
            for try await event in ws.updates() {
                if case .error = event { errors.increment() }
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        ws.connect()
        _ = await eventually { delays.values.count >= 6 }
        ws.close()
        XCTAssertEqual(Array(delays.values.prefix(6)), [1, 2, 4, 8, 16, 30])
        XCTAssertGreaterThanOrEqual(errors.count, 6)
        off.cancel()
    }

    func testCloseClosesTheSocketAndEndsTheStreams() async throws {
        let connector = FakeConnector()
        let ws = client(connector)
        let ended = SyncLog<Bool>()
        let task = Task {
            for try await _ in ws.events() {}
            ended.append(true)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await ws.subscribe(contextIds: ["c1"])
        ws.connect()
        _ = await eventually { ws.isOpen }
        ws.close()
        let finished = await eventually { ended.values == [true] }
        XCTAssertTrue(finished)
        XCTAssertTrue(connector.sockets.values.first?.isClosed ?? false)
        XCTAssertFalse(ws.isOpen)
        XCTAssertTrue(ws.subscribedContextIds.isEmpty)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(connector.sockets.values.count, 1, "no reconnect after close()")
        task.cancel()
    }

    func testMeroExposesOneSharedWsClient() {
        let mero = Mero(config: MeroConfig(baseURL: URL(string: "https://node.test")!))
        XCTAssertTrue(mero.ws === mero.ws)
        XCTAssertTrue(mero.sse === mero.sse)
    }
}
