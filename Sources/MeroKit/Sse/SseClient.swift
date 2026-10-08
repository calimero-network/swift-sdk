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

/// Server-Sent-Events subscription client — the iOS analog of mero-js's SSE
/// client. Opens `GET {base}/sse` (bearer in the `Authorization` header) and
/// POSTs `{base}/sse/subscription` to (re)subscribe to context and group ids,
/// then streams ``ContextEvent``s. Reconnects
/// automatically after a drop (the node persists session subscriptions), so a
/// chat view can react to new messages without polling.
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
    private let reconnectDelay: UInt64 = 3_000_000_000  // 3s, matches the JS client

    public init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Stream of events for the given context ids. Cancel the consuming task to
    /// close the connection.
    public func events(
        contextIds: [String], groupIds: [String] = []
    ) -> AsyncThrowingStream<ContextEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                while !Task.isCancelled {
                    do {
                        try await runOnce(contextIds: contextIds, groupIds: groupIds, continuation: continuation)
                    } catch {
                        if Task.isCancelled { break }
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: reconnectDelay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One connection attempt: open the stream, subscribe on `connect`, yield
    /// events until the stream ends or the server sends a `close`.
    private func runOnce(
        contextIds: [String], groupIds: [String],
        continuation: AsyncThrowingStream<ContextEvent, Error>.Continuation
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

            if let result = obj["result"] as? [String: Any] {
                let contextId = result["contextId"] as? String
                let groupId = result["groupId"] as? String
                guard contextId != nil || groupId != nil else { continue }
                let kind = result["type"] as? String ?? "event"
                let value =
                    (try? JSONDecoder().decode(
                        JSONValue.self, from: JSONSerialization.data(withJSONObject: result))) ?? .null
                continuation.yield(
                    ContextEvent(contextId: contextId ?? "", kind: kind, payload: value, groupId: groupId))
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
        _ = try await session.data(for: request)
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
