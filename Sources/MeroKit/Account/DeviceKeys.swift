import Foundation

#if canImport(Security)
import Security
#endif

/// This device's two keypairs: an Ed25519 signing key (what the wallet
/// certifies and what signs warrants, login statements and joins) and an
/// X25519 key-delivery ("KEM") key group keys are sealed to.
///
/// The secrets never leave the device. Only the public halves travel — to the
/// wallet, inside the certificate it returns.
public struct DeviceKeys: Codable, Sendable, Equatable {
    /// Ed25519 seed, 32 bytes.
    public let signSecret: Data
    /// X25519 private key, 32 bytes.
    public let kemSecret: Data

    public init(signSecret: Data, kemSecret: Data) throws {
        guard signSecret.count == 32, kemSecret.count == 32 else {
            throw AccountError.invalidInput("device secrets must be 32 bytes each")
        }
        self.signSecret = signSecret
        self.kemSecret = kemSecret
    }

    /// Fresh random keys.
    public static func generate() -> DeviceKeys {
        // swiftlint:disable:next force_try
        try! DeviceKeys(signSecret: randomBytes(32), kemSecret: randomBytes(32))
    }

    /// The signing seed as hex — mero-js's `deviceSecret`.
    public var deviceSecret: String { Hex.encode(signSecret) }

    /// The Ed25519 public key, 64 hex.
    public var signPublicKey: String {
        (try? Ed25519.publicKey(seed: signSecret)).map { Hex.encode($0) } ?? ""
    }

    /// The X25519 public key, 64 hex.
    public var kemPublicKey: String {
        (try? X25519.publicKey(secret: kemSecret)).map { Hex.encode($0) } ?? ""
    }

    /// Sign with the device key.
    public func sign(_ message: Data) throws -> Data {
        try Ed25519.sign(seed: signSecret, message: message)
    }

    enum CodingKeys: String, CodingKey {
        case signSecret = "sign_sk"
        case kemSecret = "kem_sk"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            signSecret: try Hex.decode(try c.decode(String.self, forKey: .signSecret), label: "sign_sk", bytes: 32),
            kemSecret: try Hex.decode(try c.decode(String.self, forKey: .kemSecret), label: "kem_sk", bytes: 32))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Hex.encode(signSecret), forKey: .signSecret)
        try c.encode(Hex.encode(kemSecret), forKey: .kemSecret)
    }
}

/// Persistence for one `Codable` value (device keys, the Cloud session).
///
/// Synchronous and thread-safe, like ``TokenStore``. The device keys must
/// survive the trip to the wallet and back, so a shipping app persists them in
/// the Keychain (``KeychainValueStore``); tests use ``MemoryValueStore``.
public protocol SecureValueStore: Sendable {
    associatedtype Value: Codable & Sendable
    func load() -> Value?
    func save(_ value: Value)
    func clear()
}

/// In-memory store. Not persisted across launches.
public final class MemoryValueStore<Value: Codable & Sendable>: SecureValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    public init(_ initial: Value? = nil) { value = initial }

    public func load() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}

#if canImport(Security)
/// Keychain-backed store: one generic-password item holding the JSON value.
///
/// Defaults to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the device
/// key is the identity of *this* device and must never migrate in a backup to
/// another one, where it would sign as a device it is not.
public final class KeychainValueStore<Value: Codable & Sendable>: SecureValueStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let accessible: CFString

    public init(
        service: String = "network.calimero.merokit",
        account: String,
        accessGroup: String? = nil,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.accessible = accessible
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func load() -> Value? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? MeroJSON.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        guard let encoded = try? MeroJSON.encode(value) else { return }
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: accessible,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = encoded
            add[kSecAttrAccessible as String] = accessible
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
#endif

/// A type-erased ``SecureValueStore`` (constrained existentials need iOS 16+
/// at runtime, and this package deploys to iOS 15).
public struct AnyValueStore<Value: Codable & Sendable>: SecureValueStore {
    private let _load: @Sendable () -> Value?
    private let _save: @Sendable (Value) -> Void
    private let _clear: @Sendable () -> Void

    public init<S: SecureValueStore>(_ store: S) where S.Value == Value {
        _load = { store.load() }
        _save = { store.save($0) }
        _clear = { store.clear() }
    }

    public func load() -> Value? { _load() }
    public func save(_ value: Value) { _save(value) }
    public func clear() { _clear() }

    /// An in-memory store.
    public static func memory(_ initial: Value? = nil) -> AnyValueStore<Value> {
        AnyValueStore(MemoryValueStore(initial))
    }

    #if canImport(Security)
    /// A Keychain item named `account` under `service`.
    public static func keychain(
        account: String, service: String = "network.calimero.merokit", accessGroup: String? = nil
    ) -> AnyValueStore<Value> {
        AnyValueStore(KeychainValueStore<Value>(service: service, account: account, accessGroup: accessGroup))
    }
    #endif
}

public extension DeviceKeys {
    /// The keys in `store`, or fresh ones (saved) if there are none.
    static func loadOrCreate(in store: AnyValueStore<DeviceKeys>) -> DeviceKeys {
        if let existing = store.load() { return existing }
        let fresh = DeviceKeys.generate()
        store.save(fresh)
        return fresh
    }
}
