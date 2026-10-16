import Foundation
import MeroKit

/// The gate for the window between "you joined" and "your data is here".
/// Port of mero-react `invitations/useJoinSync.ts`.
///
/// Without it a just-joined namespace renders its ordinary empty state, and a
/// person cannot tell an empty workspace from one still arriving.
/// ``isSyncing`` is true only for a namespace this launch just joined
/// (``markNamespaceJustJoined(_:)``), whose data has not arrived (``settled``),
/// within the watchdog: ``watchdog`` when nothing reports progress, at most
/// ``maximum`` while something does (``active``), re-checked every ``pollInterval``.
@MainActor
public final class JoinSync: ObservableObject {
    /// Base window. (== mero-react `JOIN_SYNC_WATCHDOG_MS`, in seconds.)
    public static let watchdog: TimeInterval = 30
    /// Hard ceiling. (== mero-react `JOIN_SYNC_MAX_MS`.)
    public static let maximum: TimeInterval = 120
    /// Re-check cadence past the base window. (== mero-react `JOIN_SYNC_POLL_MS`.)
    public static let pollInterval: TimeInterval = 2

    /// Show the "syncing from peers" affordance.
    @Published public private(set) var isSyncing = false

    /// The namespace shown, or `nil`.
    public private(set) var namespaceId: String?
    /// The app's own word that the namespace's data has been read — an empty
    /// answer included: "no documents yet" is settled.
    public private(set) var settled = false
    /// A sync is making progress: holds the gate past the base window, up to
    /// the ceiling. A stuck or backing-off sync reports `false`.
    public var active: Bool?

    private let store: JustJoinedNamespaces
    private let sleep: MeroSleep
    private let now: @Sendable () -> Date
    private var firstSeen: [String: Date] = [:]
    private var timer: Task<Void, Never>?
    private var timerFor: String?
    private var cancel: (() -> Void)?

    public init(
        namespaceId: String?, settled: Bool = false, active: Bool? = nil, store: JustJoinedNamespaces = .shared,
        sleep: @escaping MeroSleep = meroTaskSleep, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.namespaceId = namespaceId
        self.settled = settled
        self.active = active
        self.store = store
        self.sleep = sleep
        self.now = now
        cancel = store.subscribe { [weak self] in self?.evaluate() }
        evaluate()
    }

    /// New inputs from the page: the namespace shown, whether its data has
    /// arrived, whether a sync is progressing.
    public func update(namespaceId: String?, settled: Bool, active: Bool? = nil) {
        self.namespaceId = namespaceId
        self.settled = settled
        self.active = active
        evaluate()
    }

    /// Drop the gate now — a "show me anyway" control.
    public func dismiss() {
        guard let namespaceId else { return }
        store.clear(namespaceId)
    }

    private func evaluate() {
        let flagged = store.contains(namespaceId)
        if let namespaceId {
            if flagged, firstSeen[namespaceId] == nil {
                firstSeen[namespaceId] = now()
            } else if !flagged {
                firstSeen[namespaceId] = nil
            }
        }
        // Settled is the happy path: stop gating and forget the namespace.
        if let namespaceId, settled, flagged {
            store.clear(namespaceId)
            return
        }
        isSyncing = flagged && !settled
        armWatchdog(flagged: flagged)
    }

    private func armWatchdog(flagged: Bool) {
        guard let namespaceId, flagged, !settled else {
            timer?.cancel()
            timer = nil
            timerFor = nil
            return
        }
        // A change in activity must not restart the timer: a chatty sync
        // would postpone the deadline forever.
        guard timerFor != namespaceId || timer == nil else { return }
        timer?.cancel()
        timerFor = namespaceId
        let since = firstSeen[namespaceId] ?? now()
        let sleep = self.sleep
        let now = self.now
        timer = Task { [weak self] in
            await sleep(Self.watchdog)
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = now().timeIntervalSince(since)
                let giveUp = elapsed >= Self.maximum || (elapsed >= Self.watchdog && self.active != true)
                if giveUp {
                    self.timer = nil
                    self.timerFor = nil
                    self.store.clear(namespaceId)
                    return
                }
                await sleep(Self.pollInterval)
            }
        }
    }
}
