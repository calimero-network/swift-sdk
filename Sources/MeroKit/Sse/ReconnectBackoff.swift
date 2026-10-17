import Foundation

/// How long an event client waits before reconnecting after a drop.
///
/// The delay for the `n`th consecutive failed attempt (counting from 0) is
/// `min(initialDelay · multiplierⁿ, maxDelay)`, spread by `±jitter` (a
/// fraction) and never more than `maxDelay`. A connection that opens resets
/// the count, so a stream that ran for a while and then dropped waits
/// `initialDelay` again.
///
/// - ``sse``: 3 s first, as mero-js's `reconnectDelayMs` default, then doubling
///   to 30 s while the node keeps refusing or is unreachable, ±20% jitter.
///   mero-js waits a flat 3 s forever; the backoff only differs once a
///   reconnect has failed, and keeps a fleet of clients from retrying in step
///   against a node that is down. ``fixed(_:)`` restores the flat delay.
/// - ``webSocket``: mero-js `WsClient`'s `1 s · 2ⁿ`, capped at 30 s, no jitter.
public struct ReconnectBackoff: Sendable, Equatable {
    /// The first delay, in seconds.
    public var initialDelay: TimeInterval
    /// What each further failed attempt multiplies the delay by.
    public var multiplier: Double
    /// The longest delay, in seconds.
    public var maxDelay: TimeInterval
    /// The spread, as a fraction of the delay: `0.2` is ±20%.
    public var jitter: Double

    public init(initialDelay: TimeInterval, multiplier: Double = 2, maxDelay: TimeInterval = 30, jitter: Double = 0) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// The SSE default: 3 s, doubling to 30 s, ±20% jitter.
    public static let sse = ReconnectBackoff(initialDelay: 3, multiplier: 2, maxDelay: 30, jitter: 0.2)

    /// The WebSocket default (mero-js `WsClient`): 1 s, doubling to 30 s.
    public static let webSocket = ReconnectBackoff(initialDelay: 1, multiplier: 2, maxDelay: 30, jitter: 0)

    /// The same delay every time — mero-js `SseClient`'s `reconnectDelayMs`.
    public static func fixed(_ delay: TimeInterval) -> ReconnectBackoff {
        ReconnectBackoff(initialDelay: delay, multiplier: 1, maxDelay: delay, jitter: 0)
    }

    /// The wait before reconnect attempt `attempt` (0-based). `random` is a
    /// uniform draw in `0..<1`, injectable so tests are deterministic.
    public func delay(attempt: Int, random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 32))
        let base = min(max(initialDelay, 0) * pow(multiplier, exponent), maxDelay)
        let spread = base * jitter * (2 * random - 1)
        return min(max(0, base + spread), maxDelay)
    }
}

/// One subscriber to an event client: what to do with each event, and with
/// the end of the stream (`nil` for a normal close).
struct EventListener<Event: Sendable>: Sendable {
    let event: @Sendable (Event) -> Void
    let finish: @Sendable (Error?) -> Void
}

/// The subscribers of one event client, in the order they arrived. Not
/// thread-safe on its own: the owner keeps it under its lock, and calls the
/// listeners outside it.
struct ListenerSet<Event: Sendable> {
    private struct Entry {
        let id: Int
        let listener: EventListener<Event>
    }

    private var nextId = 0
    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(_ listener: EventListener<Event>) -> Int {
        nextId += 1
        entries.append(Entry(id: nextId, listener: listener))
        return nextId
    }

    mutating func remove(_ id: Int) {
        entries.removeAll { $0.id == id }
    }

    var all: [EventListener<Event>] { entries.map(\.listener) }

    /// Every listener, removed from the set.
    mutating func takeAll() -> [EventListener<Event>] {
        let taken = all
        entries.removeAll()
        return taken
    }
}

/// Run `operation`, failing with ``MeroError/network(_:)`` if it takes longer
/// than `seconds`. The loser is cancelled.
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval, _ label: String, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            throw MeroError.network("\(label) timed out after \(seconds) s")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// The real sleep, for reconnect timers. Returns early when cancelled.
func sleepSeconds(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
}
