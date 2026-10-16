import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One WebSocket message.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// An open WebSocket, as ``WsClient`` uses it. The SDK's own is
/// ``URLSessionWebSocketConnector``'s; tests substitute a fake.
public protocol WebSocketTransport: AnyObject, Sendable {
    /// Send one text message.
    func send(_ text: String) async throws
    /// The next message. Throws once the socket is closed or fails.
    func receive() async throws -> WebSocketMessage
    /// Close the socket. A pending ``receive()`` then throws.
    func close()
}

/// Opens WebSockets for ``WsClient``.
public protocol WebSocketConnector: Sendable {
    /// Open a socket to `url`, returning once the handshake has completed.
    func open(_ url: URL) async throws -> any WebSocketTransport
}

/// The default connector: `URLSessionWebSocketTask`.
public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(_ url: URL) async throws -> any WebSocketTransport {
        let transport = URLSessionWebSocketTransport(task: session.webSocketTask(with: url))
        transport.task.resume()
        // A task has no "open" callback without a delegate: a ping's pong is
        // the first moment the handshake is known to have completed.
        do {
            try await transport.ping()
        } catch {
            transport.close()
            throw MeroError.network("WebSocket connect failed: \(error.localizedDescription)")
        }
        return transport
    }
}

/// `URLSessionWebSocketTask` behind ``WebSocketTransport``.
final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func receive() async throws -> WebSocketMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSocketMessage, Error>) in
            task.receive { result in
                switch result {
                case .success(.string(let text)):
                    continuation.resume(returning: .text(text))
                case .success(.data(let data)):
                    continuation.resume(returning: .binary(data))
                case .success:
                    continuation.resume(returning: .binary(Data()))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// What a ``WsClient`` reports to its listeners.
public enum WsClientEvent: Sendable {
    /// The socket opened (the remembered ids are re-subscribed right after).
    case connect
    /// A context or group event.
    case event(NodeEvent)
    /// A socket failure or close; the client reconnects.
    case error(Error)
}

/// **Experimental** WebSocket event client — port of mero-js `WsClient`,
/// which is marked `@experimental` there too. ``SseConnection`` (``Mero/sse``)
/// is the recommended transport: a WebSocket message sent before the socket
/// is open is lost, which is why apps moved to SSE.
///
/// Connects to `GET {base}/ws?token=…` (http→ws, https→wss; the token rides
/// in the query because core's `/ws` reads it there). Subscriptions are
/// `{"id":null,"method":"subscribe","params":{"contextIds":[…],"groupIds":[…]}}`
/// messages (core `server-primitives` `ws.rs`), remembered and re-sent after
/// every reconnect. Reconnects with ``ReconnectBackoff/webSocket``: 1 s · 2ⁿ,
/// capped at 30 s, reset when a socket opens.
public final class WsClient: @unchecked Sendable {
    private let baseURL: URL
    private let token: @Sendable () async -> String?
    private let connector: any WebSocketConnector
    public let backoff: ReconnectBackoff
    private let sleep: @Sendable (TimeInterval) async -> Void

    private let lock = NSLock()
    private var generation = 0
    private var runTask: Task<Void, Never>?
    private var socket: (any WebSocketTransport)?
    private var contextIds: [String] = []
    private var groupIds: [String] = []
    private var listeners = ListenerSet<WsClientEvent>()

    public convenience init(
        baseURL: URL, token: @escaping @Sendable () async -> String?,
        connector: any WebSocketConnector = URLSessionWebSocketConnector(), backoff: ReconnectBackoff = .webSocket
    ) {
        self.init(baseURL: baseURL, token: token, connector: connector, backoff: backoff, sleep: sleepSeconds)
    }

    init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, connector: any WebSocketConnector,
        backoff: ReconnectBackoff, sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.baseURL = baseURL
        self.token = token
        self.connector = connector
        self.backoff = backoff
        self.sleep = sleep
    }

    /// Whether a socket is open now.
    public var isOpen: Bool { locked { socket != nil } }

    /// The context ids this client holds.
    public var subscribedContextIds: [String] { locked { contextIds } }

    /// The group ids this client holds.
    public var subscribedGroupIds: [String] { locked { groupIds } }

    /// The socket URL for `token`: `ws(s)://…/ws?token=…`.
    static func socketURL(baseURL: URL, token: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("http") { base = "ws" + base.dropFirst("http".count) }
        return URL(string: "\(base)/ws?token=\(encodeURIComponent(token))")
    }

    /// `encodeURIComponent`: everything but `A–Z a–z 0–9 - _ . ! ~ * ' ( )`.
    static func encodeURIComponent(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    // MARK: - Lifecycle

    /// Open the socket, if not already running; reconnects until ``close()``.
    public func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard runTask == nil else { return }
        generation += 1
        let current = generation
        runTask = Task { [self] in await run(generation: current) }
    }

    /// Close the socket, stop reconnecting, forget every subscription and
    /// finish every listener's stream normally.
    public func close() {
        lock.lock()
        let task = runTask
        let open = socket
        runTask = nil
        socket = nil
        generation += 1
        contextIds = []
        groupIds = []
        let finished = listeners.takeAll()
        lock.unlock()
        task?.cancel()
        open?.close()
        for listener in finished { listener.finish(nil) }
    }

    // MARK: - Subscriptions

    /// Remember ids and, when the socket is open, send a `subscribe` for them.
    /// A failed send is reported as ``WsClientEvent/error(_:)``.
    public func subscribe(contextIds: [String] = [], groupIds: [String] = []) async {
        let open = locked { () -> (any WebSocketTransport)? in
            for id in contextIds where !self.contextIds.contains(id) { self.contextIds.append(id) }
            for id in groupIds where !self.groupIds.contains(id) { self.groupIds.append(id) }
            return socket
        }
        guard let open else { return }
        await send(Self.message("subscribe", contextIds: contextIds, groupIds: groupIds), on: open)
    }

    /// Forget ids and, when the socket is open, send an `unsubscribe` for them.
    public func unsubscribe(contextIds: [String] = [], groupIds: [String] = []) async {
        let open = locked { () -> (any WebSocketTransport)? in
            self.contextIds.removeAll { contextIds.contains($0) }
            self.groupIds.removeAll { groupIds.contains($0) }
            return socket
        }
        guard let open else { return }
        await send(Self.message("unsubscribe", contextIds: contextIds, groupIds: groupIds), on: open)
    }

    /// A subscription message; empty id lists are left out, as mero-js does.
    static func message(_ method: String, contextIds: [String], groupIds: [String]) -> String {
        var params: [String: JSONValue] = [:]
        if !contextIds.isEmpty { params["contextIds"] = .array(contextIds.map { .string($0) }) }
        if !groupIds.isEmpty { params["groupIds"] = .array(groupIds.map { .string($0) }) }
        return CanonicalJSON.string(["id": .null, "method": .string(method), "params": .object(params)])
    }

    // MARK: - Listening

    /// Every client event. Ends when the client is closed. Listening does not
    /// connect: call ``connect()``.
    public func updates() -> AsyncThrowingStream<WsClientEvent, Error> {
        stream { $0 }
    }

    /// Context and group events.
    public func events() -> AsyncThrowingStream<NodeEvent, Error> {
        stream { event in
            if case .event(let nodeEvent) = event { return nodeEvent }
            return nil
        }
    }

    private func stream<Element: Sendable>(
        _ transform: @escaping @Sendable (WsClientEvent) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let listener = EventListener<WsClientEvent>(
                event: { event in
                    if let element = transform(event) { continuation.yield(element) }
                },
                finish: { error in continuation.finish(throwing: error) })
            let id = self.locked { self.listeners.add(listener) }
            continuation.onTermination = { [weak self] _ in self?.removeListener(id) }
        }
    }

    private func removeListener(_ id: Int) {
        locked { listeners.remove(id) }
    }

    // MARK: - Run loop

    private func run(generation current: Int) async {
        var attempt = 0
        while isCurrent(current) {
            do {
                try await runOnce(generation: current, attempt: &attempt)
            } catch {
                guard isCurrent(current) else { return }
                emit(.error(error), generation: current)
            }
            guard isCurrent(current) else { return }
            locked { socket = nil }
            let delay = backoff.delay(attempt: attempt)
            attempt += 1
            await sleep(delay)
        }
    }

    private func runOnce(generation current: Int, attempt: inout Int) async throws {
        guard let accessToken = await token() else {
            throw MeroError.noCredentials
        }
        guard let url = Self.socketURL(baseURL: baseURL, token: accessToken) else {
            throw MeroError.network("bad WebSocket URL for \(baseURL)")
        }
        let open = try await connector.open(url)
        let adopted = locked { () -> SubscriptionChange? in
            guard generation == current else { return nil }
            socket = open
            return SubscriptionChange(contextIds: contextIds, groupIds: groupIds)
        }
        guard let remembered = adopted else {
            open.close()
            return
        }
        attempt = 0
        emit(.connect, generation: current)
        if !remembered.isEmpty {
            await send(
                Self.message("subscribe", contextIds: remembered.contextIds, groupIds: remembered.groupIds), on: open)
        }
        while isCurrent(current) {
            let message = try await open.receive()
            guard case .text(let text) = message, let data = text.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let result = obj["result"] as? [String: Any], let event = SseClient.nodeEvent(result)
            else { continue }
            emit(.event(event), generation: current)
        }
    }

    private func send(_ message: String, on open: any WebSocketTransport) async {
        do {
            try await open.send(message)
        } catch {
            let current = locked { generation }
            emit(.error(error), generation: current)
        }
    }

    private func emit(_ event: WsClientEvent, generation current: Int) {
        let targets = locked { generation == current ? listeners.all : [] }
        for listener in targets { listener.event(event) }
    }

    private func isCurrent(_ current: Int) -> Bool {
        !Task.isCancelled && locked({ generation == current })
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
