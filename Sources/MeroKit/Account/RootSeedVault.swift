import Foundation

#if canImport(Security)
import Security
#endif

/// Where an account root's 32-byte seed rests between signatures.
///
/// The native equivalent of mero-js's non-extractable `CryptoKey` in
/// IndexedDB. A web page can hold an Ed25519 key it may use and cannot read;
/// on Apple platforms the Secure Enclave only holds P-256 keys, so the seed is
/// kept in the Keychain (``KeychainRootSeedVault``) and read by
/// ``VaultRootSigner`` for each signature — never returned to the caller.
public protocol RootSeedVault: Sendable {
    /// The seed, or `nil` when the vault holds none.
    func load() throws -> Data?
    /// Store `seed`, replacing whatever the vault held.
    func save(_ seed: Data) throws
    /// Forget the seed. Without its phrase, the account is then unreachable
    /// from this device.
    func delete() throws
}

/// A ``Signer`` for the root in a ``RootSeedVault``: it reads the seed for
/// each signature and lets it go, so no long-lived value holds the account.
public struct VaultRootSigner: Signer {
    public let publicKey: String
    private let vault: any RootSeedVault

    public init(publicKey: String, vault: any RootSeedVault) {
        self.publicKey = publicKey
        self.vault = vault
    }

    public func sign(_ payload: Data) async throws -> Data {
        guard let seed = try vault.load() else {
            throw AccountError.invalidInput("the vault holds no account root to sign with")
        }
        let signer = try SeedSigner(seed: seed, label: "rootSecret")
        guard signer.publicKey == publicKey else {
            throw AccountError.credentialRejected(
                "the vault now holds a different account root (\(signer.publicKey)), not \(publicKey)")
        }
        return try await signer.sign(payload)
    }
}

/// An in-memory ``RootSeedVault``, for tests and for a root that must not
/// outlive the process.
public final class MemoryRootSeedVault: RootSeedVault, @unchecked Sendable {
    private let lock = NSLock()
    private var seed: Data?

    public init() {}

    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return seed
    }

    public func save(_ seed: Data) throws {
        lock.lock(); defer { lock.unlock() }
        self.seed = seed
    }

    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        seed = nil
    }
}

#if canImport(Security)
/// The Keychain ``RootSeedVault``: one generic-password item holding the raw
/// 32-byte seed.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and not synchronizable: the
/// root is readable only while the device is unlocked, never leaves it in a
/// backup or through iCloud Keychain, and is never handed to the app — only
/// to ``VaultRootSigner``, for one signature at a time. The phrase is the only
/// way to move the account to another device.
public struct KeychainRootSeedVault: RootSeedVault {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = "network.calimero.merokit", account: String = "account-root", accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AccountError.protocolViolation("could not read the account root from the Keychain (\(status))")
        }
        return data
    }

    public func save(_ seed: Data) throws {
        guard seed.count == 32 else {
            throw AccountError.invalidInput("an account root seed is 32 bytes, got \(seed.count)")
        }
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = seed
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AccountError.protocolViolation("could not store the account root in the Keychain (\(status))")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountError.protocolViolation("could not delete the account root from the Keychain (\(status))")
        }
    }
}
#endif
