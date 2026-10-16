import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A node event pushed over SSE.
///
/// ``kind`` is the frame's `result.type`, and a node sends exactly two:
/// **`StateMutation`** (the context's state moved) and **`SyncStatus`**
/// (`syncing` / `waitingForPeers` / …). There is no `ExecutionEvent`, despite
/// what this comment used to say — a caller switching on one never matches.
///
/// ``payload`` is the raw frame JSON. The contract's own events are a level
/// down, under `data.events[]`, each with its own `kind` and a `data` byte
/// array carrying the encoded event.
///
/// Since core rc.83 a stream can also carry **group-keyed** events, for the
/// ids passed as `groupIds`: membership changes (`MemberJoined`,
/// `MemberAdded`, `MemberRemoved`) and migration progress
/// (`MigrationStarted`, `MigrationProgress`, `CascadeProgress`,
/// `MigrationCompleted`). Those carry ``groupId`` and an empty ``contextId``.
public struct ContextEvent: Sendable {
    /// The context the event belongs to. Empty for a group-keyed event.
    public let contextId: String
    public let kind: String
    public let payload: JSONValue
    /// The group a group-keyed event belongs to, hex. `nil` for a context event.
    public let groupId: String?

    public init(contextId: String, kind: String, payload: JSONValue, groupId: String? = nil) {
        self.contextId = contextId
        self.kind = kind
        self.payload = payload
        self.groupId = groupId
    }

    /// For a presence (`Ephemeral`) event: the account a verified device
    /// certificate names, hex. Set when an account's presence came through a
    /// relay (core rc.83); `nil` for a node's own presence and other events.
    public var presenceAccount: String? {
        guard kind == "Ephemeral", case .object(let frame) = payload,
            case .object(let data)? = frame["data"], case .string(let account)? = data["account"]
        else { return nil }
        return account
    }

    /// For a presence (`Ephemeral`) event: the signing key of the peer whose
    /// presence this is.
    public var presenceAuthor: String? {
        guard kind == "Ephemeral", case .object(let frame) = payload,
            case .object(let data)? = frame["data"], case .string(let author)? = data["author"]
        else { return nil }
        return author
    }
}

/// A group-keyed event — membership changes and migration progress —
/// delivered to a stream subscribed with `groupIds`. (== Kotlin `GroupEvent`.)
///
/// ``kind`` is the frame's `result.type` (`MemberJoined`, `MemberAdded`,
/// `MemberRemoved`, `MemberRoleChanged`, `MigrationStarted`,
/// `MigrationProgress`, `CascadeProgress`, `MigrationCompleted`; roles may
/// read `RelayTee` since core rc.83), and ``payload`` the raw `result` JSON.
public struct GroupEvent: Sendable, Equatable {
    /// The group the event belongs to, hex.
    public let groupId: String
    public let kind: String
    public let payload: JSONValue

    public init(groupId: String, kind: String, payload: JSONValue) {
        self.groupId = groupId
        self.kind = kind
        self.payload = payload
    }
}

/// Either kind of event an SSE stream delivers. (== Kotlin `NodeEvent`.)
public enum NodeEvent: Sendable {
    /// An event of a subscribed context (`StateMutation`, `SyncStatus`, …).
    case context(ContextEvent)
    /// A group-keyed event of a subscribed group.
    case group(GroupEvent)

    /// The event as the untyped ``ContextEvent`` that
    /// ``SseClient/events(contextIds:groupIds:)`` yields: a group event has an
    /// empty ``ContextEvent/contextId`` and ``ContextEvent/groupId`` set.
    public var contextEvent: ContextEvent {
        switch self {
        case .context(let event):
            return event
        case .group(let event):
            return ContextEvent(contextId: "", kind: event.kind, payload: event.payload, groupId: event.groupId)
        }
    }
}

/// The live streams one owner started, so it can cancel them all at once
/// (``Mero/close()``). Thread-safe.
final class SseStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextId = 0
    private var cancels: [Int: @Sendable () -> Void] = [:]

    /// Register a stream's cancel action; returns the id to ``remove(_:)`` it with.
    func register(_ cancel: @escaping @Sendable () -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextId += 1
        cancels[nextId] = cancel
        return nextId
    }

    func remove(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        cancels[id] = nil
    }

    /// The number of streams still registered.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels.count
    }

    /// Cancel every registered stream. The actions run outside the lock: each
    /// one finishes its stream, whose termination handler calls ``remove(_:)``.
    func cancelAll() {
        lock.lock()
        let pending = Array(cancels.values)
        cancels.removeAll()
        lock.unlock()
        for cancel in pending { cancel() }
    }
}

/// Server-Sent-Events subscription client — the iOS analog of mero-js's SSE
/// client. Opens `GET {base}/sse` (bearer in the `Authorization` header) and
/// POSTs `{base}/sse/subscription` to (re)subscribe to context and group ids,
/// then streams ``ContextEvent``s. Reconnects
/// automatically after a drop (the node persists session subscriptions), so a
/// chat view can react to new messages without polling.
///
/// A `403` is terminal. The node refuses a stream to a token that never
/// carried the right to watch those contexts, and to one whose refresh family
/// was revoked; reconnecting would only be refused again, every 3 s, forever,
/// with no event and no error. The stream finishes with that ``MeroError``
/// instead (``MeroError/authRevoked(reason:http:)`` when `x-auth-error` names a
/// dead family). Every other failure still reconnects.
///
/// Usage:
/// ```swift
/// let task = Task {
///     for try await event in mero.events(contextIds: [contextId]) {
///         await reload()   // e.g. re-fetch messages
///     }
/// }
/// // task.cancel() closes the stream.
/// ```
public final class SseClient: @unchecked Sendable {
    private let baseURL: URL
    private let token: @Sendable () async -> String?
    private let session: URLSession
    private let registry: SseStreamRegistry?
    private let reconnectDelay: UInt64 = 3_000_000_000  // 3s, matches the JS client

    public convenience init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession = .shared
    ) {
        self.init(baseURL: baseURL, token: token, session: session, registry: nil)
    }

    init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession,
        registry: SseStreamRegistry?
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.registry = registry
    }

    /// Stream of events for the given context ids (and, as ``ContextEvent``s
    /// with ``ContextEvent/groupId`` set, for `groupIds`). Cancel the consuming
    /// task to close the connection.
    public func events(
        contextIds: [String], groupIds: [String] = []
    ) -> AsyncThrowingStream<ContextEvent, Error> {
        stream(contextIds: contextIds, groupIds: groupIds) { $0.contextEvent }
    }

    /// Stream of group-keyed events (membership, migration) for `groupIds`.
    /// The node drops ids the token may not observe, silently.
    /// (== Kotlin `SseClient.groupEvents`.)
    public func groupEvents(groupIds: [String]) -> AsyncThrowingStream<GroupEvent, Error> {
        stream(contextIds: [], groupIds: groupIds) { event in
            if case .group(let group) = event { return group }
            return nil
        }
    }

    /// One stream for both: context events for `contextIds` and group events
    /// for `groupIds`, subscribed together on every (re)connect.
    /// (== Kotlin `SseClient.nodeEvents`.)
    public func nodeEvents(
        contextIds: [String], groupIds: [String]
    ) -> AsyncThrowingStream<NodeEvent, Error> {
        stream(contextIds: contextIds, groupIds: groupIds) { $0 }
    }

    /// The reconnect loop behind every public stream; `transform` picks and
    /// shapes what the caller asked for (`nil` drops an event).
    private func stream<Element: Sendable>(
        contextIds: [String], groupIds: [String],
        transform: @escaping @Sendable (NodeEvent) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let emit: @Sendable (NodeEvent) -> Void = { event in
                if let element = transform(event) { continuation.yield(element) }
            }
            let task = Task { [self] in
                while !Task.isCancelled {
                    do {
                        try await runOnce(contextIds: contextIds, groupIds: groupIds, emit: emit)
                    } catch let error as MeroError where error.httpStatus == Self.forbidden {
                        continuation.finish(throwing: error)
                        return
                    } catch {
                        if Task.isCancelled { break }
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: reconnectDelay)
                }
                continuation.finish()
            }
            // Let the owner (``Mero/close()``) end this stream; forget it once it ends.
            let owner = self.registry
            let registered = owner?.register {
                task.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                if let registered { owner?.remove(registered) }
            }
        }
    }

    /// One connection attempt: open the stream, subscribe on `connect`, yield
    /// events until the stream ends or the server sends a `close`.
    private func runOnce(
        contextIds: [String], groupIds: [String],
        emit: @Sendable (NodeEvent) -> Void
    ) async throws {
        guard let accessToken = await token() else { throw MeroError.noCredentials }

        // The bearer goes in the header, like every other call. Core still
        // accepts `?token=` on `/sse` (it is the one place a browser
        // `EventSource` needs it), but a token in a URL ends up in proxy logs.
        var request = URLRequest(url: baseURL.appendingPathComponent("sse"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600  // long-lived stream

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let http = response as? HTTPURLResponse, http.statusCode == Self.forbidden {
                throw Self.forbiddenError(http, url: request.url)
            }
            throw MeroError.network("SSE connect failed")
        }

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let type = obj["type"] as? String {
                if type == "connect", let sessionId = obj["session_id"] as? String {
                    try? await subscribe(
                        contextIds: contextIds, groupIds: groupIds, sessionId: sessionId, token: accessToken)
                } else if type == "close" {
                    return  // triggers a reconnect
                }
                continue
            }

            if let result = obj["result"] as? [String: Any], let event = Self.nodeEvent(result) {
                emit(event)
            }
        }
    }

    /// POST the subscription request (never dropped, unlike a WS message sent
    /// before the socket is open — the reason mero-chat moved to SSE).
    private func subscribe(
        contextIds: [String], groupIds: [String], sessionId: String, token: String
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("sse/subscription"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.subscriptionBody(sessionId: sessionId, contextIds: contextIds, groupIds: groupIds))
        let (_, response) = try await session.data(for: request)
        // A failed POST is normally harmless: the next `connect` re-subscribes.
        // A 403 is not; it ends the stream like a refused connect does.
        if let http = response as? HTTPURLResponse, http.statusCode == Self.forbidden {
            throw Self.forbiddenError(http, url: request.url)
        }
    }

    /// The event a frame's `result` object carries: a context event when it
    /// names a `contextId`, a group event when it names only a `groupId`, and
    /// `nil` when it names neither.
    static func nodeEvent(_ result: [String: Any]) -> NodeEvent? {
        let contextId = result["contextId"] as? String
        let groupId = result["groupId"] as? String
        guard contextId != nil || groupId != nil else { return nil }
        let kind = result["type"] as? String ?? "event"
        let value =
            (try? JSONDecoder().decode(
                JSONValue.self, from: JSONSerialization.data(withJSONObject: result))) ?? .null
        if let contextId {
            return .context(ContextEvent(contextId: contextId, kind: kind, payload: value, groupId: groupId))
        }
        return .group(GroupEvent(groupId: groupId ?? "", kind: kind, payload: value))
    }

    static let forbidden = 403

    /// The error a `403` deserves: ``MeroError/authRevoked(reason:http:)`` when
    /// `x-auth-error` names a dead token family, ``MeroError/http(_:)`` otherwise.
    static func forbiddenError(_ response: HTTPURLResponse, url: URL?) -> MeroError {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        let error = HTTPError(
            status: response.statusCode, statusText: "Forbidden", url: url?.absoluteString ?? "", headers: headers)
        if let reason = headers["x-auth-error"] { return .authRevoked(reason: reason, http: error) }
        return .http(error)
    }

    /// The subscribe body. `groupIds` is sent only when non-empty, so a
    /// context-only subscription is the exact body an older node accepts (the
    /// params are `deny_unknown_fields`).
    static func subscriptionBody(sessionId: String, contextIds: [String], groupIds: [String]) -> [String: Any] {
        var params: [String: Any] = ["contextIds": contextIds]
        if !groupIds.isEmpty { params["groupIds"] = groupIds }
        return ["id": sessionId, "method": "subscribe", "params": params]
    }
}
