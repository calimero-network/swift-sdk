import Foundation

/// An account's ephemeral presence, through its relay. Port of mero-js
/// `presence/relay-presence.ts`; a Cloud session gets one as
/// ``CloudConnection/presence``.
///
/// A node publishes and heartbeats its own presence; an account has no node,
/// so this client signs each update with the device key
/// (``PresenceStatement``), posts it to the relay's `presence-intents`, and
/// resends the last state every 2.5 s until ``set(contextId:state:codec:)``
/// with `nil` or ``close()``. The relay checks the update, then seals and
/// gossips it; other members verify the device's signature and certificate
/// themselves, so the relay cannot invent or alter an account's presence.
public actor RelayPresenceClient {
    /// The node's own heartbeat interval, so a relayed entry never outlives
    /// the 7 s presence TTL.
    public static let defaultHeartbeat: TimeInterval = 2.5

    private let relay: any PresenceRelay
    private let events: @Sendable () -> SseConnection?
    private let heartbeat: TimeInterval
    private let nowMs: @Sendable () -> UInt64
    private var timers: [String: Task<Void, Never>] = [:]
    private var lastSeq: [String: UInt64] = [:]
    private var refused: Set<String> = []
    /// Bumped by every `set` and `close`, per context. A `set` installs its
    /// resends only if nothing newer happened while its first send was in
    /// flight, so a retract (or a newer state) is never overtaken by an older one.
    private var generation: [String: Int] = [:]

    /// - Parameters:
    ///   - relay: signs and posts (a ``RelayClient``).
    ///   - events: the relay's event connection, asked for only on
    ///     ``subscribe(contextId:codec:)`` — publishing needs none, so a
    ///     session without a read token can still publish.
    ///   - heartbeat: seconds between resends.
    ///   - nowMs: the wall clock in milliseconds (injectable for tests).
    public init(
        relay: any PresenceRelay, events: @escaping @Sendable () -> SseConnection?,
        heartbeat: TimeInterval = RelayPresenceClient.defaultHeartbeat,
        nowMs: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.relay = relay
        self.events = events
        self.heartbeat = heartbeat
        self.nowMs = nowMs
    }

    /// Set this account's presence in `contextId`, or retract it with `nil`.
    ///
    /// Throws when the relay refuses this first send for good (a `4xx` other
    /// than `429`), which also stops the resends. A rate limit, a network
    /// failure or a `5xx` is not thrown: the next resend covers it.
    public func set<C: Codec>(contextId: String, state: C.Value?, codec: C) async throws {
        let current = bump(contextId)
        refused.remove(contextId)
        let bytes = try state.map { Data(try codec.encode($0)) }
        try await send(contextId, bytes)
        guard let bytes, !refused.contains(contextId), generation[contextId] == current else { return }
        let interval = heartbeat
        timers[contextId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.resend(contextId, bytes, generation: current)
            }
        }
    }

    /// ``set(contextId:state:codec:)`` with the JSON codec.
    public func set<T: Codable>(contextId: String, state: T?) async throws {
        try await set(contextId: contextId, state: state, codec: JSONCodec<T>())
    }

    /// Presence in `contextId` as the relay's event connection reports it.
    /// Fails at once when the session has no event connection.
    public nonisolated func subscribe<C: Codec>(
        contextId: String, codec: C
    ) -> AsyncThrowingStream<EphemeralEntry<C.Value>, Error> where C.Value: Sendable {
        guard let connection = events() else {
            return AsyncThrowingStream {
                $0.finish(
                    throwing: AccountError.notSignedIn(
                        "presence cannot be read: the relay session has no event connection"))
            }
        }
        return presenceStream(connection, contextId: contextId, codec: codec)
    }

    /// ``subscribe(contextId:codec:)`` with the JSON codec.
    public nonisolated func subscribe<T: Codable & Sendable>(
        contextId: String, as type: T.Type = T.self
    ) -> AsyncThrowingStream<EphemeralEntry<T>, Error> {
        subscribe(contextId: contextId, codec: JSONCodec<T>())
    }

    /// Stop every resend. Entries expire on the relay and its peers within 7 s.
    public func close() {
        for contextId in Set(timers.keys).union(generation.keys) {
            _ = bump(contextId)
        }
    }

    /// Whether `contextId` is being resent now (for tests and diagnostics).
    public func isHeartbeating(_ contextId: String) -> Bool {
        timers[contextId] != nil
    }

    // MARK: - Internals

    /// Stop the context's resends and invalidate any `set` still in flight.
    private func bump(_ contextId: String) -> Int {
        timers.removeValue(forKey: contextId)?.cancel()
        let next = (generation[contextId] ?? 0) + 1
        generation[contextId] = next
        return next
    }

    private func resend(_ contextId: String, _ bytes: Data, generation current: Int) async {
        guard generation[contextId] == current else { return }
        try? await send(contextId, bytes)
    }

    /// Wall-clock seeded and strictly rising, so a relay restart never sees an old seq.
    private func nextSeq(_ contextId: String) -> UInt64 {
        let seq = max(nowMs(), (lastSeq[contextId] ?? 0) + 1)
        lastSeq[contextId] = seq
        return seq
    }

    private func send(_ contextId: String, _ state: Data?) async throws {
        guard !refused.contains(contextId) else { return }
        let seq = nextSeq(contextId)
        do {
            try await relay.presenceIntent(contextId: contextId, state: state, seq: seq, sentAtMs: nowMs())
        } catch {
            // Rate limited, a network failure, or the relay unable right now
            // (5xx, e.g. no current key mid-rotation): the next resend covers it.
            if Self.isTransient(error) { return }
            // Any other refusal (403: not a member or revoked; 400: malformed,
            // or a clock outside the relay's window) — or a statement that
            // cannot be signed — cannot be fixed by resending.
            refused.insert(contextId)
            timers.removeValue(forKey: contextId)?.cancel()
            throw error
        }
    }

    /// Whether the next resend may succeed where this send failed.
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError || error is CancellationError { return true }
        switch error {
        case MeroError.network, MeroError.decoding, MeroError.emptyResponse:
            return true
        default:
            guard let status = status(of: error) else { return false }
            return status == 0 || status == 429 || status >= 500
        }
    }

    static func status(of error: Error) -> Int? {
        if let mero = error as? MeroError { return mero.httpStatus }
        if case AccountError.intentRefused(_, _, let status) = error { return status }
        return nil
    }
}
