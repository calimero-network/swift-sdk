import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A node event pushed over SSE. `payload` is the raw event JSON — for a
/// contract emission (`type == "ExecutionEvent"`) the events live under
/// `data.events[].data` (a byte array carrying the encoded contract event).
public struct ContextEvent: Sendable {
    public let contextId: String
    public let kind: String
    public let payload: JSONValue
}

/// Server-Sent-Events subscription client — the iOS analog of mero-js's SSE
/// client. Opens `GET {base}/sse?token=…` and POSTs `{base}/sse/subscription`
/// to (re)subscribe to context ids, then streams ``ContextEvent``s. Reconnects
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
    public func events(contextIds: [String]) -> AsyncThrowingStream<ContextEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                while !Task.isCancelled {
                    do {
                        try await runOnce(contextIds: contextIds, continuation: continuation)
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
        contextIds: [String], continuation: AsyncThrowingStream<ContextEvent, Error>.Continuation
    ) async throws {
        guard let accessToken = await token() else { throw MeroError.noCredentials }

        var comps = URLComponents(
            url: baseURL.appendingPathComponent("sse"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "token", value: accessToken)]
        guard let url = comps?.url else { throw MeroError.network("invalid SSE URL") }

        var request = URLRequest(url: url)
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
                    try? await subscribe(contextIds: contextIds, sessionId: sessionId, token: accessToken)
                } else if type == "close" {
                    return  // triggers a reconnect
                }
                continue
            }

            if let result = obj["result"] as? [String: Any], let contextId = result["contextId"] as? String {
                let kind = result["type"] as? String ?? "event"
                let value =
                    (try? JSONDecoder().decode(
                        JSONValue.self, from: JSONSerialization.data(withJSONObject: result))) ?? .null
                continuation.yield(ContextEvent(contextId: contextId, kind: kind, payload: value))
            }
        }
    }

    /// POST the subscription request (never dropped, unlike a WS message sent
    /// before the socket is open — the reason mero-chat moved to SSE).
    private func subscribe(contextIds: [String], sessionId: String, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("sse/subscription"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": sessionId, "method": "subscribe", "params": ["contextIds": contextIds],
        ])
        _ = try await session.data(for: request)
    }
}
