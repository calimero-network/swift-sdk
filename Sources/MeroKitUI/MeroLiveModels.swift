import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

/// A sleep the live models use, injectable so tests need not wait.
public typealias MeroSleep = @Sendable (TimeInterval) async -> Void

/// `Task.sleep` for `seconds`; returns early when cancelled.
public let meroTaskSleep: MeroSleep = { seconds in
    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
}

/// Calls `onChange` (on the main actor) after every session change of a
/// ``MeroClient`` — what a hook's dependency on `mero`/`admin` is in mero-react.
@MainActor
final class MeroSessionWatch {
    #if canImport(Combine)
    private var cancellable: AnyCancellable?
    #endif

    init(_ client: MeroClient, onChange: @escaping @MainActor @Sendable () -> Void) {
        #if canImport(Combine)
        cancellable = client.$sessionRevision.dropFirst().sink { _ in
            Task { @MainActor in onChange() }
        }
        #endif
    }
}

// MARK: - Execute

/// Run contract methods in one context, with `isLoading` / `error`.
/// (== mero-react `useExecute`.)
@MainActor
public final class ContextExecutor: ObservableObject {
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    private weak var client: MeroClient?
    public let contextId: String?
    public let executorId: String?

    public init(client: MeroClient, contextId: String?, executorId: String?) {
        self.client = client
        self.contextId = contextId
        self.executorId = executorId
    }

    /// Call `method` with `params`; `nil` (with ``error`` set) on failure or
    /// with nothing to send it through. An account with no relay yet is told
    /// so ("no relay"), not "not connected": it is connected.
    public func execute<T: Decodable & Sendable>(
        _ method: String, params: [String: JSONValue] = [:], as type: T.Type = T.self
    ) async -> T? {
        guard let transport = client?.transport, let contextId, let executorId, !executorId.isEmpty else {
            let noRelay = client?.transport == nil && client?.isDelegated == true
            error = noRelay ? NotConnectedError.noRelay : NotConnectedError()
            return nil
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        let rpc = transport.rpc
        do {
            let value: T = try await rpc.execute(contextId: contextId, method: method, argsJson: params)
            return value
        } catch {
            self.error = error
            return nil
        }
    }
}

// MARK: - Subscription

/// Context and group events for some ids, delivered to `handler` on the
/// main actor, re-opened when the session changes. (== mero-react `useSubscription`.)
@MainActor
public final class EventSubscription: ObservableObject {
    public let contextIds: [String]
    public let groupIds: [String]
    private weak var client: MeroClient?
    private let handler: @MainActor (NodeEvent) -> Void
    private var listen: Task<Void, Never>?
    private var watch: MeroSessionWatch?

    public init(
        client: MeroClient, contextIds: [String] = [], groupIds: [String] = [],
        handler: @escaping @MainActor (NodeEvent) -> Void
    ) {
        self.client = client
        self.contextIds = contextIds
        self.groupIds = groupIds
        self.handler = handler
        watch = MeroSessionWatch(client) { [weak self] in self?.start() }
        start()
    }

    /// (Re)open the stream against the current session.
    public func start() {
        cancel()
        guard !contextIds.isEmpty || !groupIds.isEmpty, let events = try? client?.transport?.events else { return }
        let stream = events.events()
        events.connect()
        let contextIds = contextIds
        let groupIds = groupIds
        Task { _ = try? await events.subscribe(contextIds: contextIds, groupIds: groupIds) }
        listen = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    self.handler(event)
                }
            } catch {
                // The connection stopped for good; the session's own health
                // handling reports it.
            }
        }
    }

    /// Stop listening (the connection stays up for others).
    public func cancel() {
        listen?.cancel()
        listen = nil
    }
}

// MARK: - Context discovery

/// Wait for a context of an application to appear: by alias first, else any
/// context not among the known ones. (== mero-react `useContextDiscovery`.)
@MainActor
public final class ContextDiscovery: ObservableObject {
    @Published public private(set) var context: ApplicationContextRecord?
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    private weak var client: MeroClient?
    public let applicationId: String
    public let knownContextIds: Set<String>
    public let targetAlias: String?
    public let pollInterval: TimeInterval
    public let timeout: TimeInterval
    private let sleep: MeroSleep
    private let now: @Sendable () -> Date

    public init(
        client: MeroClient, applicationId: String, knownContextIds: [String] = [], targetAlias: String? = nil,
        pollInterval: TimeInterval = 1, timeout: TimeInterval = 30, sleep: @escaping MeroSleep = meroTaskSleep,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.applicationId = applicationId
        self.knownContextIds = Set(knownContextIds)
        self.targetAlias = targetAlias
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.sleep = sleep
        self.now = now
    }

    /// Poll until a context is found or ``timeout`` passes.
    @discardableResult
    public func discover() async -> ApplicationContextRecord? {
        guard let admin = client?.admin, let read = client?.readAdmin else {
            error = NotConnectedError()
            return nil
        }
        let deadline = now().addingTimeInterval(timeout)
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            while now() <= deadline {
                if let found = try await poll(admin: admin, read: read) {
                    context = found
                    return found
                }
                if now().addingTimeInterval(pollInterval) > deadline || Task.isCancelled { break }
                await sleep(pollInterval)
            }
            context = nil
            error = NotConnectedError("Timed out discovering a context for application \(applicationId)")
            return nil
        } catch {
            context = nil
            self.error = error
            return nil
        }
    }

    private func poll(admin: any AdminSurface, read: AdminApi) async throws -> ApplicationContextRecord? {
        if let targetAlias, let match = try await admin.lookupContextAlias(targetAlias).value,
            !knownContextIds.contains(match)
        {
            return ApplicationContextRecord(contextId: match, applicationId: applicationId)
        }
        let listed = try await read.getContextsForApplication(applicationId).contexts
        return listed.first { !knownContextIds.contains($0.id) }
            .map { ApplicationContextRecord(contextId: $0.id, applicationId: $0.applicationId) }
    }

    public func reset() {
        context = nil
        error = nil
        isLoading = false
    }
}

// MARK: - Ephemeral presence

/// Observe and publish ephemeral presence (cursors, typing, online) for one
/// context. (== mero-react `useEphemeral`.)
///
/// One read path: the subscription, whose replay seeds and whose deltas update
/// ``peers``. A replay is authoritative: once its burst ends
/// (``replayReconcileWindow`` after its last entry), a peer it did not mention
/// is dropped, so one swept while the connection was down does not linger.
/// Your own echo is filtered out unless `includeSelf`, by the context
/// identity this node owns. ``setPresence(_:)`` is trailing-edge throttled: the
/// newest value wins.
@MainActor
public final class EphemeralPresence<State: Codable & Sendable>: ObservableObject {
    /// author → their slice.
    @Published public private(set) var peers: [String: State] = [:]
    /// Why your own presence cannot be filtered (no owned identity), latched.
    @Published public private(set) var identityError: Error?
    /// The last publish's failure, if it failed.
    @Published public private(set) var publishError: Error?

    /// How long after the last replayed entry the replay is reconciled.
    public static var replayReconcileWindow: TimeInterval { 0.05 }

    public let contextId: String?
    public let includeSelf: Bool
    public let throttle: TimeInterval
    private weak var client: MeroClient?
    private let sleep: MeroSleep
    private let now: @Sendable () -> Date
    private var selfAuthor: String?
    private var receivedAt: [String: Date] = [:]
    private var lastLocal: State?
    private var pending: State?
    private var lastSentAt: Date
    private var timer: Task<Void, Never>?
    private var replaySeen: Set<String>?
    private var replayTimer: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var identity: Task<Void, Never>?
    private var watch: MeroSessionWatch?

    public init(
        client: MeroClient, contextId: String?, initial: State? = nil, throttle: TimeInterval = 0.03,
        includeSelf: Bool = false, sleep: @escaping MeroSleep = meroTaskSleep,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.contextId = contextId
        self.includeSelf = includeSelf
        self.throttle = throttle
        self.lastLocal = initial
        self.sleep = sleep
        self.now = now
        // Seeded to now so a call shortly after start is throttled too.
        self.lastSentAt = now()
        watch = MeroSessionWatch(client) { [weak self] in self?.start() }
        start()
    }

    /// The error worth reporting: an unresolved identity matters only when
    /// your own echo is to be filtered.
    public var error: Error? { publishError ?? (includeSelf ? nil : identityError) }

    /// How long ago `author`'s entry was current, or `nil`. A replayed entry
    /// counts from when the node last heard it (`ageMs`), a live one from now.
    public func ageOf(_ author: String) -> TimeInterval? {
        receivedAt[author].map { now().timeIntervalSince($0) }
    }

    /// (Re)subscribe against the current session.
    public func start() {
        stop()
        guard let contextId, let transport = client?.transport else { return }
        identity = Task { [weak self] in
            let owned = try? await transport.admin.getContextIdentitiesOwned(contextId).identities.first
            guard let self, !Task.isCancelled else { return }
            self.adoptSelf(owned)
        }
        reading = Task { [weak self] in
            guard let surface = try? await transport.ephemeral else { return }
            let stream: AsyncThrowingStream<EphemeralEntry<State>, Error>
            switch surface {
            case .node(let ephemeral):
                stream = ephemeral.subscribe(contextId: contextId, codec: JSONCodec<State>())
            case .relay(let presence):
                stream = presence.subscribe(contextId: contextId, codec: JSONCodec<State>())
            }
            do {
                for try await entry in stream {
                    guard let self else { return }
                    self.apply(entry)
                }
            } catch {
                // The connection's own health handling reports a dead stream.
            }
        }
    }

    /// Stop reading and drop queued publishes.
    public func stop() {
        reading?.cancel()
        identity?.cancel()
        timer?.cancel()
        replayTimer?.cancel()
        reading = nil
        identity = nil
        timer = nil
        replayTimer = nil
        replaySeen = nil
        pending = nil
    }

    private func adoptSelf(_ owned: String?) {
        selfAuthor = owned
        guard let owned else {
            identityError = NotConnectedError(
                "could not resolve a local context identity, so your own presence cannot be filtered out; "
                    + "pass includeSelf: true to accept this")
            return
        }
        identityError = nil
        if !includeSelf {
            receivedAt[owned] = nil
            peers[owned] = nil
        }
    }

    func apply(_ entry: EphemeralEntry<State>) {
        if entry.ageMs != nil {
            if replaySeen == nil { replaySeen = [] }
            replayTimer?.cancel()
            let window = Self.replayReconcileWindow
            let sleep = self.sleep
            replayTimer = Task { [weak self] in
                await sleep(window)
                guard !Task.isCancelled else { return }
                self?.closeReplayWindow()
            }
        }
        guard !entry.removed, let state = entry.state else {
            replaySeen?.remove(entry.author)
            receivedAt[entry.author] = nil
            peers[entry.author] = nil
            return
        }
        if !includeSelf, entry.author == selfAuthor { return }
        replaySeen?.insert(entry.author)
        let age = TimeInterval(entry.ageMs ?? 0) / 1000
        receivedAt[entry.author] = now().addingTimeInterval(-age)
        peers[entry.author] = state
    }

    private func closeReplayWindow() {
        replayTimer = nil
        guard let seen = replaySeen else { return }
        replaySeen = nil
        for author in peers.keys where !seen.contains(author) {
            peers[author] = nil
            receivedAt[author] = nil
        }
    }

    /// Publish your own presence: `update` edits the last value you set
    /// (starting from `initial`). Presence is one slot per author, so this
    /// replaces your whole slot with the edited value.
    public func setPresence(_ update: (inout State) -> Void) {
        guard var next = lastLocal else { return }
        update(&next)
        setPresence(next)
    }

    /// Publish `value` as your whole presence slot.
    public func setPresence(_ value: State) {
        lastLocal = value
        guard throttle > 0 else {
            publish(value)
            return
        }
        pending = value
        guard timer == nil else { return }
        let delay = max(throttle - now().timeIntervalSince(lastSentAt), 0)
        let sleep = self.sleep
        timer = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            if let queued = self.pending {
                self.pending = nil
                self.publish(queued)
            }
        }
    }

    private func publish(_ value: State) {
        guard let contextId, let transport = client?.transport else { return }
        lastSentAt = now()
        Task { [weak self] in
            do {
                switch try await transport.ephemeral {
                case .node(let ephemeral):
                    try await ephemeral.set(contextId: contextId, state: value, codec: JSONCodec<State>())
                case .relay(let presence):
                    try await presence.set(contextId: contextId, state: value, codec: JSONCodec<State>())
                }
                guard let self, self.contextId == contextId else { return }
                self.publishError = nil
            } catch {
                guard let self, self.contextId == contextId else { return }
                self.publishError = error
            }
        }
    }
}
