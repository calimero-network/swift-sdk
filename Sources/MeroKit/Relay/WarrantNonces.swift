import Foundation

/// Where a device's warrant nonces come from.
///
/// A warrant nonce is spent on the node, so the counter must outlive the app:
/// a restart that began again at 1 would replay spent nonces and be refused.
/// One monotonic `UInt64` sequence **per relay** (not per context) — the node's
/// per-`(context, device)` ledger accepts any unseen nonce above its floor, so a
/// single rising sequence shared by every context only ever skips, which is free.
public protocol WarrantNonceStore: Sendable {
    /// The next nonce for `relay` (starting at 1), persisted before returning.
    func next(relay: String) -> UInt64
    /// Make sure the next nonce handed out for `relay` is at least `floor`.
    func advance(relay: String, to floor: UInt64)
}

/// Lock-protected base for both stores.
private final class NonceLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let read: (String) -> UInt64
    private let write: (String, UInt64) -> Void

    init(read: @escaping (String) -> UInt64, write: @escaping (String, UInt64) -> Void) {
        self.read = read
        self.write = write
    }

    func next(_ key: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let value = read(key) &+ 1
        write(key, value)
        return value
    }

    func advance(_ key: String, to floor: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let wanted = floor > 0 ? floor - 1 : 0
        if wanted > read(key) { write(key, wanted) }
    }
}

/// In-memory nonces (tests, or a process that owns its whole sequence).
public final class MemoryWarrantNonceStore: WarrantNonceStore, @unchecked Sendable {
    private var values: [String: UInt64] = [:]
    private lazy var ledger = NonceLedger(
        read: { [unowned self] in values[$0] ?? 0 }, write: { [unowned self] in values[$0] = $1 })

    public init() {}

    public func next(relay: String) -> UInt64 { ledger.next(Self.key(relay)) }
    public func advance(relay: String, to floor: UInt64) { ledger.advance(Self.key(relay), to: floor) }

    static func key(_ relay: String) -> String {
        var trimmed = relay
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// Nonces persisted in `UserDefaults` (stored as decimal strings so a `UInt64`
/// never passes through a `Double`).
public final class UserDefaultsWarrantNonceStore: WarrantNonceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String
    private lazy var ledger = NonceLedger(
        read: { [unowned self] in UInt64(defaults.string(forKey: prefix + $0) ?? "") ?? 0 },
        write: { [unowned self] in defaults.set(String($1), forKey: prefix + $0) })

    public init(defaults: UserDefaults = .standard, prefix: String = "calimero.nonce.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func next(relay: String) -> UInt64 { ledger.next(MemoryWarrantNonceStore.key(relay)) }
    public func advance(relay: String, to floor: UInt64) {
        ledger.advance(MemoryWarrantNonceStore.key(relay), to: floor)
    }
}
