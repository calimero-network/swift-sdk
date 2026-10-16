import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What an ``SseConnection`` reports to its listeners.
public enum SseConnectionEvent: Sendable {
    /// A connection (or reconnection) is up, and every remembered id has been
    /// re-subscribed on it (or the re-subscribe failed, reported next as an
    /// ``error(_:)``). (== mero-js `'connect'`.)
    case connect(sessionId: String)
    /// A context or group event.
    case event(NodeEvent)
    /// A failure the connection recovers from by reconnecting: a dropped
    /// stream, a refused re-subscribe, a refused connect that is not terminal.
    /// (== mero-js `'error'`.)
    case error(Error)
}

/// One long-lived Server-Sent-Events connection to a node — the port of
/// mero-js's `SseClient` object (``SseClient`` keeps the one-stream-per-call
/// API on top of it).
///
/// The connection remembers what it is subscribed to. ``subscribe(contextIds:groupIds:)``
/// and ``unsubscribe(contextIds:groupIds:)`` change that set on the live
/// session (`POST /sse/subscription`, 10 s timeout), and after every reconnect
/// the whole remembered set is re-subscribed before ``SseConnectionEvent/connect(sessionId:)``
/// is announced. Ids subscribed before the first connect are sent then.
///
/// **Reconnects** follow ``ReconnectBackoff/sse`` unless told otherwise. A
/// `403` — on the stream or on a re-subscribe — is terminal, as are a `401`
/// whose `x-auth-error` names a dead token family (`token_revoked`,
/// `token_reuse`): reconnecting would only send the same dead credential
/// again. The connection stops and every listener's stream finishes with that
/// ``MeroError`` (``MeroError/authRevoked(reason:http:)`` when the header
/// names the family). ``connect()`` starts it again.
///
/// **Presence**: the node replays a context's current presence once, when the
/// context is first subscribed on a connection. The connection keeps what that
/// replay and the live `Ephemeral` deltas said (``presenceSeed(_:)``), so a
/// presence subscriber that arrives later still sees everyone.
///
/// ```swift
/// let sse = mero.sse
/// sse.connect()
/// try await sse.subscribe(contextIds: [contextId])
/// for try await change in sse.appVersionChanges() { … }
/// ```
public final class SseConnection: @unchecked Sendable {
    /// How long a subscription POST may take before it counts as failed.
    public static let subscriptionTimeout: TimeInterval = 10

    private let baseURL: URL
    private let authorize: RequestAuthorizer
    private let session: URLSession
    public let backoff: ReconnectBackoff
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let random: @Sendable () -> Double
    private let now: @Sendable () -> Date
    /// ``subscriptionTimeout``, shortened by tests.
    private let postTimeout: TimeInterval

    private let lock = NSLock()
    /// Bumped by every ``connect()`` start, ``close()`` and terminal failure,
    /// so a run loop that lost the race stops touching the state.
    private var generation = 0
    private var runTask: Task<Void, Never>?
    private var _sessionId: String?
    private var contextIds: [String] = []
    private var groupIds: [String] = []
    private var presence: [String: PresenceBook] = [:]
    private var listeners = ListenerSet<SseConnectionEvent>()

    public convenience init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession = .shared,
        backoff: ReconnectBackoff = .sse
    ) {
        self.init(baseURL: baseURL, authorize: bearerAuthorizer(token), session: session, backoff: backoff)
    }

    /// A connection authorized per request — a device certificate signing a
    /// request proof (``createProofAuthorizer(_:)``) instead of a bearer
    /// token. The stream and every subscription POST are signed; a request
    /// carrying `X-Calimero-Proof` never follows a redirect. (== mero-js
    /// `SseClient({ authorize })`.)
    public convenience init(
        baseURL: URL, authorize: @escaping RequestAuthorizer, session: URLSession = .shared,
        backoff: ReconnectBackoff = .sse
    ) {
        self.init(
            baseURL: baseURL, authorize: authorize, session: session, backoff: backoff, sleep: sleepSeconds,
            random: { Double.random(in: 0..<1) }, now: { Date() })
    }

    convenience init(
        baseURL: URL, token: @escaping @Sendable () async -> String?, session: URLSession,
        backoff: ReconnectBackoff, sleep: @escaping @Sendable (TimeInterval) async -> Void,
        random: @escaping @Sendable () -> Double, now: @escaping @Sendable () -> Date,
        postTimeout: TimeInterval = SseConnection.subscriptionTimeout
    ) {
        self.init(
            baseURL: baseURL, authorize: bearerAuthorizer(token), session: session, backoff: backoff, sleep: sleep,
            random: random, now: now, postTimeout: postTimeout)
    }

    init(
        baseURL: URL, authorize: @escaping RequestAuthorizer, session: URLSession,
        backoff: ReconnectBackoff, sleep: @escaping @Sendable (TimeInterval) async -> Void,
        random: @escaping @Sendable () -> Double, now: @escaping @Sendable () -> Date,
        postTimeout: TimeInterval = SseConnection.subscriptionTimeout
    ) {
        self.postTimeout = postTimeout
        self.baseURL = baseURL
        self.authorize = authorize
        self.session = session
        self.backoff = backoff
        self.sleep = sleep
        self.random = random
        self.now = now
    }

    // MARK: - State

    /// The node's id for the current session, `nil` while not connected.
    public var sessionId: String? { locked { _sessionId } }

    /// Whether a run loop is going (connected, connecting or waiting to reconnect).
    public var isRunning: Bool { locked { runTask != nil } }

    /// The context ids this connection holds, in the order they were added.
    public var subscribedContextIds: [String] { locked { contextIds } }

    /// The group ids this connection holds, in the order they were added.
    public var subscribedGroupIds: [String] { locked { groupIds } }

    /// Whether this connection holds `contextId`'s events.
    public func isSubscribed(_ contextId: String) -> Bool { locked { contextIds.contains(contextId) } }

    /// Whether this connection holds `groupId`'s events.
    public func isSubscribed(groupId: String) -> Bool { locked { groupIds.contains(groupId) } }

    /// The presence currently known for `contextId`, as `Ephemeral` event data
    /// objects (`author`, `account?`, `state?`, `ageMs`), each one's `ageMs`
    /// advanced by how long ago it arrived. Empty for a context this
    /// connection does not hold. (== mero-js `presenceSeed`.)
    public func presenceSeed(_ contextId: String) -> [JSONValue] {
        let at = now()
        return locked { presence[contextId]?.seed(now: at) ?? [] }
    }

    // MARK: - Lifecycle

    /// Open the stream, if it is not already running. Returns at once; the
    /// connection then runs, and reconnects, until ``close()`` or a terminal
    /// failure.
    public func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard runTask == nil else { return }
        generation += 1
        let current = generation
        runTask = Task { [self] in await run(generation: current) }
    }

    /// Stop: cancel the stream and any reconnect, forget every subscription and
    /// the presence kept for them, and finish every listener's stream
    /// normally. ``connect()`` may be called again afterwards.
    public func close() {
        lock.lock()
        let task = runTask
        runTask = nil
        generation += 1
        _sessionId = nil
        contextIds = []
        groupIds = []
        presence = [:]
        let finished = listeners.takeAll()
        lock.unlock()
        task?.cancel()
        for listener in finished { listener.finish(nil) }
    }

    // MARK: - Subscriptions

    /// Add ids to what this connection holds. Ids it already holds are not
    /// sent again; new ones are POSTed to the live session at once (or with
    /// the next connect, when there is no session yet). Throws when that POST
    /// fails or takes more than ``subscriptionTimeout``; the ids stay
    /// remembered either way, so the next reconnect sends them.
    public func subscribe(contextIds: [String] = [], groupIds: [String] = []) async throws {
        let (added, sessionId) = locked { () -> (SubscriptionChange, String?) in
            let added = SubscriptionChange(
                contextIds: Self.insert(contextIds, into: &self.contextIds),
                groupIds: Self.insert(groupIds, into: &self.groupIds))
            return (added, _sessionId)
        }
        guard !added.isEmpty, let sessionId else { return }
        try await postSubscription(method: "subscribe", added, sessionId: sessionId)
    }

    /// Remove ids from what this connection holds, and forget the presence
    /// kept for those contexts. Ids it held are POSTed as an `unsubscribe` to
    /// the live session.
    public func unsubscribe(contextIds: [String] = [], groupIds: [String] = []) async throws {
        let (removed, sessionId) = locked { () -> (SubscriptionChange, String?) in
            let removed = SubscriptionChange(
                contextIds: Self.remove(contextIds, from: &self.contextIds),
                groupIds: Self.remove(groupIds, from: &self.groupIds))
            for id in removed.contextIds { presence[id] = nil }
            return (removed, _sessionId)
        }
        guard !removed.isEmpty, let sessionId else { return }
        try await postSubscription(method: "unsubscribe", removed, sessionId: sessionId)
    }

    /// Remember ids without sending anything (the next connect sends them).
    func remember(contextIds: [String], groupIds: [String]) {
        locked {
            _ = Self.insert(contextIds, into: &self.contextIds)
            _ = Self.insert(groupIds, into: &self.groupIds)
        }
    }

    // MARK: - Listening

    /// Every connection event: connects, node events and recoverable errors.
    /// Ends when the connection is closed, and throws when it stops on a
    /// terminal failure. Listening does not connect: call ``connect()``.
    public func updates() -> AsyncThrowingStream<SseConnectionEvent, Error> {
        stream { $0 }
    }

    /// Context and group events, untyped.
    public func events() -> AsyncThrowingStream<NodeEvent, Error> {
        stream { event in
            if case .event(let nodeEvent) = event { return nodeEvent }
            return nil
        }
    }

    /// `AppVersionChanged` context events, parsed. (== mero-js `onAppVersionChanged`.)
    public func appVersionChanges() -> AsyncThrowingStream<AppVersionChangedEvent, Error> {
        stream { Self.appVersionChange($0) }
    }

    /// Group-migration events, typed. A non-admin never sees `cascadeProgress`.
    /// (== mero-js `onMigrationEvent`.)
    public func migrationEvents() -> AsyncThrowingStream<GroupMigrationEvent, Error> {
        stream { Self.migration($0) }
    }

    /// Group-membership events (`MemberJoined`, `MemberAdded`, `MemberRemoved`), typed.
    public func membershipEvents() -> AsyncThrowingStream<GroupMembershipEvent, Error> {
        stream { event in
            if case .event(.group(let group)) = event { return group.membership }
            return nil
        }
    }

    /// Call `handler` for every connection event until the returned closure
    /// is called (or the connection closes). (== mero-js `on`/`off`.)
    @discardableResult
    public func on(_ handler: @escaping @Sendable (SseConnectionEvent) -> Void) -> @Sendable () -> Void {
        let id = addListener(EventListener(event: handler, finish: { _ in }))
        return { [weak self] in self?.removeListener(id) }
    }

    /// Call `handler` for each `AppVersionChanged` event; returns the
    /// unsubscribe closure. (== mero-js `onAppVersionChanged`.)
    @discardableResult
    public func onAppVersionChanged(
        _ handler: @escaping @Sendable (AppVersionChangedEvent) -> Void
    ) -> @Sendable () -> Void {
        on { event in
            if let change = Self.appVersionChange(event) { handler(change) }
        }
    }

    /// Call `handler` for each group-migration event; returns the unsubscribe
    /// closure. (== mero-js `onMigrationEvent`.)
    @discardableResult
    public func onMigrationEvent(
        _ handler: @escaping @Sendable (GroupMigrationEvent) -> Void
    ) -> @Sendable () -> Void {
        on { event in
            if let migration = Self.migration(event) { handler(migration) }
        }
    }

    private static func appVersionChange(_ event: SseConnectionEvent) -> AppVersionChangedEvent? {
        if case .event(.context(let context)) = event { return context.appVersionChanged }
        return nil
    }

    private static func migration(_ event: SseConnectionEvent) -> GroupMigrationEvent? {
        if case .event(.group(let group)) = event { return group.migration }
        return nil
    }

    /// A stream of what `transform` keeps of each event.
    func stream<Element: Sendable>(
        _ transform: @escaping @Sendable (SseConnectionEvent) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let id = self.addListener(
                EventListener(
                    event: { event in
                        if let element = transform(event) { continuation.yield(element) }
                    },
                    finish: { error in continuation.finish(throwing: error) }))
            continuation.onTermination = { [weak self] _ in self?.removeListener(id) }
        }
    }

    /// Add a listener. With `seedPresenceFor`, a context this connection
    /// already holds first has its kept presence replayed to the listener, as
    /// `Ephemeral` events, atomically with joining — so no live delta is missed
    /// or seen twice. The listener is called under the lock for the seed, so
    /// it must not call back into the connection.
    func addListener(
        _ listener: EventListener<SseConnectionEvent>, seedPresenceFor contextId: String? = nil
    ) -> Int {
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        if let contextId, contextIds.contains(contextId) {
            for data in presence[contextId]?.seed(now: at) ?? [] {
                let payload: JSONValue = ["contextId": .string(contextId), "type": "Ephemeral", "data": data]
                let event = ContextEvent(contextId: contextId, kind: "Ephemeral", payload: payload)
                listener.event(.event(.context(event)))
            }
        }
        return listeners.add(listener)
    }

    func removeListener(_ id: Int) {
        locked { listeners.remove(id) }
    }

    // MARK: - Run loop

    private func run(generation current: Int) async {
        var attempt = 0
        while isCurrent(current) {
            do {
                try await runOnce(generation: current, attempt: &attempt)
            } catch let error where Self.isTerminal(error) {
                terminate(error, generation: current)
                return
            } catch {
                guard isCurrent(current) else { return }
                emit(.error(error), generation: current)
            }
            guard isCurrent(current) else { return }
            locked { _sessionId = nil }
            let delay = backoff.delay(attempt: attempt, random: random())
            attempt += 1
            await sleep(delay)
        }
    }

    /// One connection: open the stream, re-subscribe on `connect`, dispatch
    /// events until the stream ends or the server sends `close`.
    private func runOnce(generation current: Int, attempt: inout Int) async throws {
        // The credential (a bearer token, or a request proof) goes in a
        // header, like every other call. For a token, core still
        // accepts `?token=` on `/sse` (it is the one place a browser
        // `EventSource` needs it), but a token in a URL ends up in proxy logs.
        let url = baseURL.appendingPathComponent("sse")
        var request = URLRequest(url: url)
        let authorization = try await authorize(ProofRequest(method: "GET", path: signedPath(url)))
        for (name, value) in authorization { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600  // long-lived stream
        let proofAttached = carriesProof(authorization)

        let (bytes, response) = try await session.bytes(
            for: request, delegate: proofAttached ? ProofRedirectRefusal() : nil)
        guard let http = response as? HTTPURLResponse else { throw MeroError.network("SSE connect failed") }
        if proofAttached, (300..<400).contains(http.statusCode) {
            throw proofRedirectError(url: url.absoluteString, headers: Self.headers(http))
        }
        guard http.statusCode == 200 else {
            throw Self.failure(status: http.statusCode, headers: Self.headers(http), url: request.url)
        }
        attempt = 0

        for try await line in bytes.lines {
            guard isCurrent(current) else { return }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let type = obj["type"] as? String {
                if type == "connect", let sessionId = obj["session_id"] as? String {
                    try await handleConnect(sessionId, generation: current)
                } else if type == "close" {
                    return  // triggers a reconnect
                }
                continue
            }

            if let result = obj["result"] as? [String: Any], let event = SseClient.nodeEvent(result) {
                dispatch(event, generation: current)
            }
        }
    }

    /// A new session starts subscribed to nothing: re-subscribe everything
    /// remembered, then announce it. A refused re-subscribe still announces,
    /// then reports the failure — except a `403`, which is terminal.
    private func handleConnect(_ sessionId: String, generation current: Int) async throws {
        let remembered = locked { () -> SubscriptionChange? in
            guard generation == current else { return nil }
            _sessionId = sessionId
            // A new connection gets a new replay when it re-subscribes; what
            // the old one said may name authors who have since gone.
            presence = [:]
            return SubscriptionChange(contextIds: contextIds, groupIds: groupIds)
        }
        guard let remembered else { return }
        var failure: Error?
        if !remembered.isEmpty {
            do {
                try await postSubscription(method: "subscribe", remembered, sessionId: sessionId)
            } catch {
                if Self.isTerminal(error) { throw error }
                failure = error
            }
        }
        guard locked({ generation == current && _sessionId == sessionId }) else { return }
        emit(.connect(sessionId: sessionId), generation: current)
        if let failure { emit(.error(failure), generation: current) }
    }

    private func dispatch(_ event: NodeEvent, generation current: Int) {
        let targets = locked { () -> [EventListener<SseConnectionEvent>] in
            guard generation == current else { return [] }
            if case .context(let context) = event, context.kind == "Ephemeral" {
                notePresence(context)
            }
            return listeners.all
        }
        for listener in targets { listener.event(.event(event)) }
    }

    /// Keep an `Ephemeral` event's data for ``presenceSeed(_:)``. Under the lock.
    private func notePresence(_ event: ContextEvent) {
        guard contextIds.contains(event.contextId), case .object(let data)? = event.data,
            case .string(let author)? = data["author"]
        else { return }
        var book = presence[event.contextId] ?? PresenceBook()
        if Self.truthy(data["removed"]) {
            book.remove(author)
        } else {
            book.set(author, data: data, at: now())
        }
        presence[event.contextId] = book
    }

    private func emit(_ event: SseConnectionEvent, generation current: Int) {
        let targets = locked { generation == current ? listeners.all : [] }
        for listener in targets { listener.event(event) }
    }

    /// Stop on a terminal failure: no reconnect, every listener finishes with
    /// `error`. Subscriptions stay remembered for a later ``connect()``.
    private func terminate(_ error: Error, generation current: Int) {
        lock.lock()
        guard generation == current else {
            lock.unlock()
            return
        }
        generation += 1
        runTask = nil
        _sessionId = nil
        let finished = listeners.takeAll()
        lock.unlock()
        for listener in finished { listener.finish(error) }
    }

    private func isCurrent(_ current: Int) -> Bool {
        !Task.isCancelled && locked({ generation == current })
    }

    // MARK: - Subscription POST

    private func postSubscription(method: String, _ ids: SubscriptionChange, sessionId: String) async throws {
        let url = baseURL.appendingPathComponent("sse/subscription")
        let body = try JSONSerialization.data(
            withJSONObject: SseClient.subscriptionBody(
                sessionId: sessionId, contextIds: ids.contextIds, groupIds: ids.groupIds, method: method))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = postTimeout
        let authorization = try await authorize(ProofRequest(method: "POST", path: signedPath(url), body: body))
        for (name, value) in authorization { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let proofAttached = carriesProof(authorization)
        let session = self.session
        let sent = request
        let answer = try await withTimeout(postTimeout, "SSE \(method)") { () -> SubscriptionAnswer in
            let (_, response) = try await session.data(
                for: sent, delegate: proofAttached ? ProofRedirectRefusal() : nil)
            guard let http = response as? HTTPURLResponse else { throw MeroError.network("SSE \(method) failed") }
            return SubscriptionAnswer(status: http.statusCode, headers: Self.headers(http))
        }
        if proofAttached, (300..<400).contains(answer.status) {
            throw proofRedirectError(url: url.absoluteString, headers: answer.headers)
        }
        guard (200..<300).contains(answer.status) else {
            throw Self.failure(status: answer.status, headers: answer.headers, url: request.url)
        }
    }

    // MARK: - Helpers

    /// Reasons in `x-auth-error` that mean the whole token family is gone.
    static let terminalAuthErrors: Set<String> = ["token_reuse", "token_revoked"]

    /// A `403`, or a dead token family: reconnecting cannot succeed.
    static func isTerminal(_ error: Error) -> Bool {
        if case MeroError.authRevoked = error { return true }
        return (error as? MeroError)?.httpStatus == SseClient.forbidden
    }

    /// The error a refused SSE request deserves:
    /// ``MeroError/authRevoked(reason:http:)`` for a `403` carrying any
    /// `x-auth-error` or a `401` naming a dead family, ``MeroError/http(_:)``
    /// otherwise.
    static func failure(status: Int, headers: [String: String], url: URL?) -> MeroError {
        let error = HTTPError(
            status: status, statusText: HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
            url: url?.absoluteString ?? "", headers: headers)
        if let reason = headers["x-auth-error"] {
            if status == SseClient.forbidden || (status == 401 && terminalAuthErrors.contains(reason)) {
                return .authRevoked(reason: reason, http: error)
            }
        }
        return .http(error)
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k.lowercased()] = v }
        }
        return headers
    }

    /// JavaScript truthiness, for the `removed` flag.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        case .null?, nil: return false
        }
    }

    /// Append the ids `into` lacks (once each); returns those added.
    private static func insert(_ ids: [String], into set: inout [String]) -> [String] {
        var added: [String] = []
        for id in ids where !set.contains(id) {
            set.append(id)
            added.append(id)
        }
        return added
    }

    /// Remove the ids `from` holds; returns those removed.
    private static func remove(_ ids: [String], from set: inout [String]) -> [String] {
        var removed: [String] = []
        for id in ids where set.contains(id) {
            set.removeAll { $0 == id }
            removed.append(id)
        }
        return removed
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Ids added to or removed from a subscription.
struct SubscriptionChange: Sendable {
    let contextIds: [String]
    let groupIds: [String]
    var isEmpty: Bool { contextIds.isEmpty && groupIds.isEmpty }
}

/// A subscription POST's answer, as far as it matters.
private struct SubscriptionAnswer: Sendable {
    let status: Int
    let headers: [String: String]
}

/// One context's presence: author → that author's last `Ephemeral` data and
/// when it arrived, in arrival order.
struct PresenceBook {
    private struct Slot {
        let data: [String: JSONValue]
        let at: Date
    }

    private var order: [String] = []
    private var slots: [String: Slot] = [:]

    mutating func set(_ author: String, data: [String: JSONValue], at: Date) {
        if slots[author] == nil { order.append(author) }
        slots[author] = Slot(data: data, at: at)
    }

    mutating func remove(_ author: String) {
        slots[author] = nil
        order.removeAll { $0 == author }
    }

    /// Each kept entry with `ageMs` advanced to `now`.
    func seed(now: Date) -> [JSONValue] {
        order.compactMap { author in
            guard let slot = slots[author] else { return nil }
            var data = slot.data
            let base = data["ageMs"]?.doubleValue ?? 0
            let elapsed = max(0, (now.timeIntervalSince(slot.at) * 1000).rounded(.down))
            data["ageMs"] = .number(base + elapsed)
            return .object(data)
        }
    }
}

/// The bearer-token authorizer every token-based SSE client uses: the access
/// token in `Authorization`, or ``MeroError/noCredentials`` when there is none.
func bearerAuthorizer(_ token: @escaping @Sendable () async -> String?) -> RequestAuthorizer {
    { _ in
        guard let accessToken = await token() else { throw MeroError.noCredentials }
        return ["Authorization": "Bearer \(accessToken)"]
    }
}
