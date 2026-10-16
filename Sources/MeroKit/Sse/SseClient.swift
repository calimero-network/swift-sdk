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
/// client. Each stream this hands out is its own ``SseConnection``: it opens
/// `GET {base}/sse` (bearer in the `Authorization` header), POSTs
/// `{base}/sse/subscription` for the ids it was asked for on every
/// (re)connect, and streams the events. Reconnects automatically after a drop,
/// with ``ReconnectBackoff/sse`` (3 s, doubling to 30 s while the node stays
/// unreachable), so a chat view can react to new messages without polling.
///
/// For one shared connection whose subscriptions change while it runs, use
/// ``connection()`` (or ``Mero/sse``).
///
/// A `403` is terminal. The node refuses a stream to a token that never
/// carried the right to watch those contexts, and to one whose refresh family
/// was revoked; reconnecting would only be refused again, forever, with no
/// event and no error. The stream finishes with that ``MeroError`` instead
/// (``MeroError/authRevoked(reason:http:)`` when `x-auth-error` names a dead
/// family, or a `401` names `token_revoked`/`token_reuse`). Every other
/// failure reconnects.
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
    private let backoff: ReconnectBackoff
    private let sleep: @Sendable (TimeInterval) async -> Void

    public convenience init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession = .shared,
        backoff: ReconnectBackoff = .sse
    ) {
        self.init(baseURL: baseURL, token: token, session: session, registry: nil, backoff: backoff)
    }

    init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession,
        registry: SseStreamRegistry?, backoff: ReconnectBackoff = .sse,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = sleepSeconds
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.registry = registry
        self.backoff = backoff
        self.sleep = sleep
    }

    /// A new, unconnected long-lived connection with this client's node,
    /// token and backoff. Call ``SseConnection/connect()`` and
    /// ``SseConnection/subscribe(contextIds:groupIds:)`` on it.
    public func connection() -> SseConnection {
        SseConnection(
            baseURL: baseURL, token: token, session: session, backoff: backoff, sleep: sleep,
            random: { Double.random(in: 0..<1) }, now: { Date() })
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

    /// `AppVersionChanged` events of `contextIds`, parsed.
    /// (== mero-js `onAppVersionChanged`.)
    public func appVersionChanges(contextIds: [String]) -> AsyncThrowingStream<AppVersionChangedEvent, Error> {
        stream(contextIds: contextIds, groupIds: []) { event in
            if case .context(let context) = event { return context.appVersionChanged }
            return nil
        }
    }

    /// Migration events of `groupIds` (namespace roots), typed.
    /// (== mero-js `onMigrationEvent`.)
    public func migrationEvents(groupIds: [String]) -> AsyncThrowingStream<GroupMigrationEvent, Error> {
        stream(contextIds: [], groupIds: groupIds) { event in
            if case .group(let group) = event { return group.migration }
            return nil
        }
    }

    /// A stream on its own connection, subscribed to `contextIds`/`groupIds`;
    /// `transform` picks and shapes what the caller asked for (`nil` drops an
    /// event). Ending the stream closes the connection.
    private func stream<Element: Sendable>(
        contextIds: [String], groupIds: [String],
        transform: @escaping @Sendable (NodeEvent) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let connection = self.connection()
            connection.remember(contextIds: contextIds, groupIds: groupIds)
            _ = connection.addListener(
                EventListener(
                    event: { event in
                        if case .event(let nodeEvent) = event, let element = transform(nodeEvent) {
                            continuation.yield(element)
                        }
                    },
                    finish: { error in continuation.finish(throwing: error) }))
            // Let the owner (``Mero/close()``) end this stream; forget it once it ends.
            let owner = self.registry
            let registered = owner?.register { connection.close() }
            continuation.onTermination = { _ in
                connection.close()
                if let registered { owner?.remove(registered) }
            }
            connection.connect()
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
        SseConnection.failure(status: response.statusCode, headers: SseConnection.headers(response), url: url)
    }

    /// The subscription body. `groupIds` is sent only when non-empty, so a
    /// context-only subscription is the exact body an older node accepts (the
    /// params are `deny_unknown_fields`).
    static func subscriptionBody(
        sessionId: String, contextIds: [String], groupIds: [String], method: String = "subscribe"
    ) -> [String: Any] {
        var params: [String: Any] = ["contextIds": contextIds]
        if !groupIds.isEmpty { params["groupIds"] = groupIds }
        return ["id": sessionId, "method": method, "params": params]
    }
}
