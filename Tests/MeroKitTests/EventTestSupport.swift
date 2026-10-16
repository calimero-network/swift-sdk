import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A thread-safe, append-only log of values, for callbacks and fakes.
final class SyncLog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }
}

/// A settable clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        _now = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

/// Poll `condition` until it holds or `timeout` passes; returns whether it held.
func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// SSE wire frames.
enum Frames {
    static func connect(_ sessionId: String) -> String {
        "data: {\"type\":\"connect\",\"session_id\":\"\(sessionId)\"}\n\n"
    }

    static func result(_ json: String) -> String {
        "data: {\"result\":\(json)}\n\n"
    }

    /// An `Ephemeral` event for `contextId` with `data` (JSON text).
    static func ephemeral(_ contextId: String, _ data: String) -> String {
        result("{\"contextId\":\"\(contextId)\",\"type\":\"Ephemeral\",\"data\":\(data)}")
    }

    /// The JSON byte array of `text`'s UTF-8, as `state` travels.
    static func bytes(_ text: String) -> String {
        "[" + Array(text.utf8).map { String($0) }.joined(separator: ",") + "]"
    }
}

/// Serves `/sse` from a script — one stub per connect, the last one repeated —
/// and answers everything else with `subscription` (default `200 {}`),
/// recording every request in order.
final class ScriptedNode: @unchecked Sendable {
    let recorded = RequestRecorder()
    private let lock = NSLock()
    private var streams: [MockURLProtocol.Stub]
    private let subscription: @Sendable (URLRequest) -> MockURLProtocol.Stub

    init(
        streams: [MockURLProtocol.Stub],
        subscription: @escaping @Sendable (URLRequest) -> MockURLProtocol.Stub = { _ in
            .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
    ) {
        self.streams = streams
        self.subscription = subscription
    }

    /// A `/sse` that sends `frames` and stays open.
    static func open(_ frames: String) -> MockURLProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(frames.utf8), holdOpen: true)
    }

    /// A `/sse` that sends `frames` and ends (the client then reconnects).
    static func ending(_ frames: String) -> MockURLProtocol.Stub {
        .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(frames.utf8))
    }

    func install() {
        MockURLProtocol.setHandler { [self] req in
            recorded.append(req)
            if req.url?.path.hasSuffix("/sse") == true { return nextStream() }
            return subscription(req)
        }
    }

    private func nextStream() -> MockURLProtocol.Stub {
        lock.lock(); defer { lock.unlock() }
        return streams.count > 1 ? streams.removeFirst() : streams[0]
    }

    /// The subscription POSTs so far, as JSON bodies.
    var subscriptions: [[String: Any]] {
        recorded.requests.filter { $0.path.hasSuffix("/sse/subscription") }.compactMap(\.jsonBody)
    }

    var streamOpens: Int {
        recorded.requests.filter { $0.path.hasSuffix("/sse") }.count
    }
}

extension SseConnection {
    /// A connection on ``MockURLProtocol`` whose reconnect sleep is recorded
    /// (and short), with an injectable clock.
    static func testing(
        clock: TestClock = TestClock(), delays: SyncLog<TimeInterval> = SyncLog(),
        backoff: ReconnectBackoff = .sse, postTimeout: TimeInterval = SseConnection.subscriptionTimeout
    ) -> SseConnection {
        SseConnection(
            baseURL: URL(string: "https://node.test")!, token: { "T" }, session: MockURLProtocol.makeSession(),
            backoff: backoff,
            sleep: { delay in
                delays.append(delay)
                try? await Task.sleep(nanoseconds: 5_000_000)
            },
            random: { 0.5 }, now: { clock.now }, postTimeout: postTimeout)
    }
}

/// What an ``SseConnection`` reported, in a comparable shape.
enum Seen: Equatable {
    case connect(String)
    case event(String)
    case error(Int?)
}

extension SseConnection {
    /// Record every connection event into `log`.
    func record(into log: SyncLog<Seen>) {
        on { event in
            switch event {
            case .connect(let sessionId): log.append(.connect(sessionId))
            case .event(let nodeEvent): log.append(.event(nodeEvent.contextEvent.kind))
            case .error(let error): log.append(.error((error as? MeroError)?.httpStatus))
            }
        }
    }
}
