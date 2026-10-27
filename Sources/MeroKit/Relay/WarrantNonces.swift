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
    /// Forget every sequence. Only safe with the device keys they were spent
    /// under: a node refuses a nonce its ledger has seen from that device, so
    /// ``CloudSignIn/signOut(forgetDevice:)`` clears them with the keys, never
    /// alone. A store that cannot forget keeps them (the default).
    func clear()
}

public extension WarrantNonceStore {
    func clear() {}
}

/// The process-wide warrant nonces.
public enum WarrantNonces {
    /// One Keychain item (`warrant-nonces`) on Apple platforms, taking over
    /// any sequence an earlier version kept in `UserDefaults`
    /// (``StoredWarrantNonceStore/keychain(account:service:accessGroup:migratingFrom:legacyPrefix:)``);
    /// `UserDefaults` elsewhere. Shared so every client draws from one lock.
    public static let shared: any WarrantNonceStore = {
        #if canImport(Security)
        return StoredWarrantNonceStore.keychain()
        #else
        return UserDefaultsWarrantNonceStore()
        #endif
    }()
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

    /// Run `body` under the ledger's lock (a clear must not interleave a `next`).
    func locked(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        body()
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
    public func clear() { ledger.locked { values = [:] } }

    static func key(_ relay: String) -> String {
        var trimmed = relay
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// Nonces persisted in `UserDefaults` (stored as decimal strings so a `UInt64`
/// never passes through a `Double`). `UserDefaults` is a cleartext plist that
/// rides in backups and links the device to its relays, so on Apple platforms
/// the default is ``StoredWarrantNonceStore/keychain(account:service:accessGroup:migratingFrom:legacyPrefix:)``;
/// use this one only by choice.
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

    public func clear() {
        ledger.locked { UserDefaultsWarrantNonceStore.removeAll(prefix: prefix, from: defaults) }
    }

    static func removeAll(prefix: String, from defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Nonces kept in one ``SecureValueStore`` item, `relay → last nonce` (decimal
/// strings) — the Keychain by default
/// (``keychain(account:service:accessGroup:migratingFrom:legacyPrefix:)``).
///
/// It takes over a ``UserDefaultsWarrantNonceStore``'s sequences on first use
/// without going backwards: each is moved in (the larger value kept) and its
/// `UserDefaults` entry deleted once the store reads it back.
/// What this process handed out is held in memory too, so a store that cannot
/// be read for a moment (the Keychain before first unlock) never restarts a
/// sequence that was spent.
public final class StoredWarrantNonceStore: WarrantNonceStore, @unchecked Sendable {
    private let store: AnyValueStore<[String: String]>
    private let legacy: UserDefaults?
    private let legacyPrefix: String
    private var handedOut: [String: UInt64] = [:]
    private var migrated = false
    private lazy var ledger = NonceLedger(
        read: { [unowned self] in read($0) }, write: { [unowned self] in write($0, $1) })

    /// - Parameters:
    ///   - legacy: `UserDefaults` an earlier version kept nonces in, to move
    ///     them from (`nil` for none).
    ///   - legacyPrefix: their key prefix there.
    public init(
        _ store: AnyValueStore<[String: String]>, migratingFrom legacy: UserDefaults? = nil,
        legacyPrefix: String = "calimero.nonce."
    ) {
        self.store = store
        self.legacy = legacy
        self.legacyPrefix = legacyPrefix
    }

    #if canImport(Security)
    /// Nonces in one Keychain item (`…ThisDeviceOnly`, like the device keys
    /// they are spent with), moving any left in `UserDefaults`.
    public static func keychain(
        account: String = "warrant-nonces", service: String = "network.calimero.merokit", accessGroup: String? = nil,
        migratingFrom legacy: UserDefaults? = .standard, legacyPrefix: String = "calimero.nonce."
    ) -> StoredWarrantNonceStore {
        StoredWarrantNonceStore(
            .keychain(account: account, service: service, accessGroup: accessGroup), migratingFrom: legacy,
            legacyPrefix: legacyPrefix)
    }
    #endif

    public func next(relay: String) -> UInt64 { ledger.next(MemoryWarrantNonceStore.key(relay)) }
    public func advance(relay: String, to floor: UInt64) {
        ledger.advance(MemoryWarrantNonceStore.key(relay), to: floor)
    }

    public func clear() {
        ledger.locked {
            handedOut = [:]
            migrated = true
            store.clear()
            if let legacy { UserDefaultsWarrantNonceStore.removeAll(prefix: legacyPrefix, from: legacy) }
        }
    }

    /// Move every sequence left in `UserDefaults` into the store, keeping the
    /// larger value; each entry is deleted once the store reads it back. Tried
    /// on each access until nothing is left to move.
    private func migrateLegacy() {
        guard !migrated else { return }
        guard let legacy else {
            migrated = true
            return
        }
        var moved: [String: UInt64] = [:]
        for (name, value) in legacy.dictionaryRepresentation() where name.hasPrefix(legacyPrefix) {
            guard let nonce = (value as? String).flatMap({ UInt64($0) }) else { continue }
            moved[String(name.dropFirst(legacyPrefix.count))] = nonce
        }
        guard !moved.isEmpty else {
            migrated = true
            return
        }
        for (key, nonce) in moved { handedOut[key] = max(handedOut[key] ?? 0, nonce) }
        persist()
        let stored = store.load() ?? [:]
        var left = false
        for (key, nonce) in moved {
            if let kept = stored[key].flatMap({ UInt64($0) }), kept >= nonce {
                legacy.removeObject(forKey: legacyPrefix + key)
            } else {
                left = true
            }
        }
        migrated = !left
    }

    private func read(_ key: String) -> UInt64 {
        migrateLegacy()
        let stored = store.load().flatMap { $0[key] }.flatMap { UInt64($0) } ?? 0
        return max(handedOut[key] ?? 0, stored)
    }

    private func write(_ key: String, _ value: UInt64) {
        handedOut[key] = value
        persist()
    }

    /// Save what the store holds merged with what this process handed out, so
    /// a read that failed cannot drop another relay's sequence from the item.
    private func persist() {
        var all = store.load() ?? [:]
        for (relay, held) in handedOut where held > (all[relay].flatMap { UInt64($0) } ?? 0) {
            all[relay] = String(held)
        }
        store.save(all)
    }
}
