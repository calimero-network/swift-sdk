import Foundation

// Creating an account root, and proving you hold one.
//
// Port of mero-js `src/account/account.ts`. Where the root comes from (a
// 24-word BIP39 phrase), how a person keeps it (written down; on device, in the
// Keychain behind a ``Signer`` that never hands the seed out), and how they
// show Calimero Cloud they have it (`signAccountLink`, `signAccountLogin`).
// Everything here is offline and holds no state.
//
// **Interop note, and it matters.** The phrase encodes the root secret as BIP39
// *entropy*, not as a BIP39 *seed*. A tool restoring it must take the 32 bytes
// `mnemonicToEntropy(phrase)` returns and use them as the Ed25519 seed
// directly. `mnemonicToSeed(phrase)` runs PBKDF2 and returns 64 different
// bytes, which name a different account. There is no passphrase and no BIP32
// derivation path: the 24 words are the key.

/// mdma's `ACCOUNT_LINK_DOMAIN`, trailing NUL included. Prefixed raw, not run
/// through `domainHash`: mdma verifies `ed25519_verify(root_pk, domain ‖ nonce)`.
let accountLinkDomain = Data("calimero.mdma.account-link.v1\0".utf8)
/// mdma's `ACCOUNT_LOGIN_DOMAIN`, trailing NUL included. Separate from the
/// link domain so a link signature cannot be replayed as a login.
let accountLoginDomain = Data("calimero.mdma.account-login.v1\0".utf8)

/// An account root: the secret, the key it derives, and the account it names.
public struct AccountRoot: Sendable, Equatable {
    /// The root signing secret, 64 hex. The whole account: never sent anywhere,
    /// and on device it belongs in the Keychain (``KeychainRootSeedVault``).
    public let secret: String
    /// The root's Ed25519 public key, 64 hex. Safe to publish.
    public let publicKey: String
    /// The account this root names, 64 hex — the content address of its genesis.
    public let accountId: String
}

/// An account root together with the phrase that restores it.
public struct RecoverableAccountRoot: Sendable, Equatable {
    public let secret: String
    public let publicKey: String
    public let accountId: String
    /// The 24-word BIP39 English recovery phrase, single-space separated.
    /// Show it once, have the holder write it down, and do not keep it.
    public let phrase: String

    /// The root without its phrase.
    public var root: AccountRoot { AccountRoot(secret: secret, publicKey: publicKey, accountId: accountId) }
}

/// An account root held as a key this app may use and cannot read.
///
/// There is deliberately no `secret` beside the signer: nothing downstream
/// of here can be handed the account.
public struct AccountRootSigner: Sendable {
    /// The root's Ed25519 public key, 64 hex.
    public let publicKey: String
    /// The account this root names, 64 hex.
    public let accountId: String
    /// Signs for the root: pass it to ``signOwnerOpProof(_:)``,
    /// ``signDeviceScope(_:)``, ``signAccountLink(_:)``.
    public let signer: any Signer
}

/// A freshly minted root signer, with the phrase that is its only backup.
public struct NewAccountRootSigner: Sendable {
    public let publicKey: String
    public let accountId: String
    public let signer: any Signer
    /// The 24-word phrase. Show it **once**, and store it nowhere: the signer
    /// beside it never gives the seed back, so a holder who does not write
    /// these words down has no path back to the account from another device.
    public let phrase: String

    /// The signer without its phrase.
    public var rootSigner: AccountRootSigner {
        AccountRootSigner(publicKey: publicKey, accountId: accountId, signer: signer)
    }
}

/// The account root, in either form a caller may hold it: the 64-hex secret,
/// or a ``Signer`` this process may use and cannot read. (== mero-js `RootSource`.)
public enum RootSource: Sendable {
    case secret(String)
    case signer(any Signer)
}

/// A root's identity and how it signs, however the caller supplied it.
public struct ResolvedRoot: Sendable {
    public let signer: any Signer
    /// The root's Ed25519 public key, 64 hex.
    public let publicKey: String
    /// The account it names, 64 hex.
    public let accountId: String
}

// MARK: - Minting and restoring

/// Entropy carried by a phrase: 256 bits, an Ed25519 seed exactly.
private let entropyBytes = 32
/// 11 bits per word: (256 + 8 checksum bits) / 11 = 24 words.
private let phraseWords = 24

/// Mint a brand-new account root from the system CSPRNG, with its 24-word
/// phrase. See the interop note at the top of this file.
public func generateAccountRoot() throws -> RecoverableAccountRoot {
    let entropy = randomBytes(entropyBytes)
    return try recoverable(entropy: entropy, phrase: encodePhrase(entropy))
}

/// Restore an account root from its recovery phrase.
///
/// Whitespace and case are normalised (NFKD, lowercase, any run of
/// whitespace). A word outside the list, a wrong word count, or a failed
/// checksum throws rather than returning some other account.
public func accountRootFromPhrase(_ phrase: String) throws -> RecoverableAccountRoot {
    let words = try normalisePhrase(phrase)
    return try recoverable(entropy: try decodePhrase(words), phrase: words.joined(separator: " "))
}

/// The public half of a root you already hold.
public func accountRootFromSecret(_ secret: String) throws -> AccountRoot {
    let signer = try signerFromSecret(secret, label: "secret")
    return AccountRoot(
        secret: secret, publicKey: signer.publicKey,
        accountId: try DeviceCertificates.account(forRootPublicKey: signer.publicKey))
}

/// Mint a root whose seed stays inside its signer, and hand back its phrase.
///
/// Without a `vault` the seed lives only in the returned signer, in memory.
/// With one (``KeychainRootSeedVault`` on device) it is saved there and the
/// signer reads it per signature, so it survives a relaunch; reopen it with
/// ``loadAccountRootSigner(from:)``. Either way no `secret` is returned.
public func createAccountRootSigner(vault: (any RootSeedVault)? = nil) throws -> NewAccountRootSigner {
    let entropy = randomBytes(entropyBytes)
    let phrase = encodePhrase(entropy)
    let root = try makeRootSigner(entropy: entropy, vault: vault)
    return NewAccountRootSigner(
        publicKey: root.publicKey, accountId: root.accountId, signer: root.signer, phrase: phrase)
}

/// Restore the same root on another device from its phrase. The same 24 words
/// reach the same account id anywhere, with no server involved. With a
/// `vault`, the seed is saved there (replacing what it held).
public func accountRootSignerFromPhrase(
    _ phrase: String, vault: (any RootSeedVault)? = nil
) throws -> AccountRootSigner {
    try makeRootSigner(entropy: try decodePhrase(try normalisePhrase(phrase)), vault: vault)
}

/// The root a vault holds, or `nil` when it holds none.
public func loadAccountRootSigner(from vault: any RootSeedVault) throws -> AccountRootSigner? {
    guard let seed = try vault.load() else { return nil }
    let publicKey = try SeedSigner(seed: seed, label: "rootSecret").publicKey
    return AccountRootSigner(
        publicKey: publicKey, accountId: try DeviceCertificates.account(forRootPublicKey: publicKey),
        signer: VaultRootSigner(publicKey: publicKey, vault: vault))
}

private func makeRootSigner(entropy: Data, vault: (any RootSeedVault)?) throws -> AccountRootSigner {
    let seedSigner = try SeedSigner(seed: entropy, label: "rootSecret")
    let signer: any Signer
    if let vault {
        try vault.save(entropy)
        signer = VaultRootSigner(publicKey: seedSigner.publicKey, vault: vault)
    } else {
        signer = seedSigner
    }
    return AccountRootSigner(
        publicKey: seedSigner.publicKey,
        accountId: try DeviceCertificates.account(forRootPublicKey: seedSigner.publicKey), signer: signer)
}

private func recoverable(entropy: Data, phrase: String) throws -> RecoverableAccountRoot {
    let root = try accountRootFromSecret(Hex.encode(entropy))
    return RecoverableAccountRoot(
        secret: root.secret, publicKey: root.publicKey, accountId: root.accountId, phrase: phrase)
}

// MARK: - Resolving

/// What a root is, however it was supplied: who it is, and how it signs.
public func resolveRoot(_ source: RootSource) throws -> ResolvedRoot {
    switch source {
    case .secret(let secret): return try identify(try signerFromSecret(secret, label: "rootSecret"))
    case .signer(let signer): return try identify(signer)
    }
}

/// The same, for entry points that take the two forms as separate optional
/// fields. Exactly one must be present (see ``resolveSigner(_:_:label:)``).
public func resolveRootPair(rootSecret: String?, signer: (any Signer)?) throws -> ResolvedRoot {
    try identify(try resolveSigner(rootSecret, signer, label: "rootSecret"))
}

private func identify(_ signer: any Signer) throws -> ResolvedRoot {
    ResolvedRoot(
        signer: signer, publicKey: signer.publicKey,
        accountId: try DeviceCertificates.account(forRootPublicKey: signer.publicKey))
}

// MARK: - Proving the root to the cloud

/// What ``signAccountLink(_:)`` needs: the root (a secret or a signer,
/// exactly one) and the cloud's challenge.
public struct AccountLinkInput: Sendable {
    /// The account root's signing secret, 64 hex. Prefer ``signer``.
    public var rootSecret: String?
    /// The root's signer — use instead of ``rootSecret``.
    public var signer: (any Signer)?
    /// The challenge from `GET /api/cloud/me/accounts/challenge`, verbatim.
    /// Signed as its UTF-8 bytes.
    public var nonce: String

    public init(rootSecret: String? = nil, signer: (any Signer)? = nil, nonce: String) {
        self.rootSecret = rootSecret
        self.signer = signer
        self.nonce = nonce
    }
}

/// What ``signAccountLogin(_:)`` needs.
public struct AccountLoginInput: Sendable {
    public var rootSecret: String?
    public var signer: (any Signer)?
    /// The challenge from `GET /api/auth/account/challenge`, verbatim UTF-8.
    public var nonce: String

    public init(rootSecret: String? = nil, signer: (any Signer)? = nil, nonce: String) {
        self.rootSecret = rootSecret
        self.signer = signer
        self.nonce = nonce
    }
}

/// Sign a cloud link challenge with the account root. Returns **standard**
/// base64 (mdma decodes with `validate=True`, refusing base64url).
///
/// Root-signed rather than device-signed on purpose: this is the credential
/// someone still holds after losing a device.
public func signAccountLink(_ input: AccountLinkInput) async throws -> String {
    guard !input.nonce.isEmpty else { throw AccountError.invalidInput("nonce is required to sign an account link") }
    let signer = try resolveSigner(input.rootSecret, input.signer, label: "rootSecret")
    let signature = try await signChecked(signer, accountLinkDomain + Data(input.nonce.utf8))
    return signature.base64EncodedString()
}

/// Sign a cloud login challenge with the account root: *"I hold the root of
/// account X"*, the one statement a device credential can never make.
/// Returns standard base64.
public func signAccountLogin(_ input: AccountLoginInput) async throws -> String {
    guard !input.nonce.isEmpty else { throw AccountError.invalidInput("nonce is required to sign an account login") }
    let signer = try resolveSigner(input.rootSecret, input.signer, label: "rootSecret")
    let signature = try await signChecked(signer, accountLoginDomain + Data(input.nonce.utf8))
    return signature.base64EncodedString()
}

// MARK: - BIP39

/// Word → index in ``bip39EnglishWordlist``.
private let bip39Index: [String: Int] = {
    var index: [String: Int] = [:]
    for (i, word) in bip39EnglishWordlist.enumerated() { index[word] = i }
    return index
}()

private func normalisePhrase(_ phrase: String) throws -> [String] {
    // NFKD per BIP39: a no-op for the ASCII English list, but what the spec pins.
    let words = phrase.decomposedStringWithCompatibilityMapping.lowercased()
        .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard words.count == phraseWords else {
        throw AccountError.invalidInput("recovery phrase must be \(phraseWords) words, got \(words.count)")
    }
    return words
}

/// Entropy then its 8-bit checksum (the first byte of SHA-256), cut into
/// 24 11-bit word indices.
func encodePhrase(_ entropy: Data) -> String {
    let bytes = [UInt8](entropy) + [sha256(entropy)[0]]
    var words: [String] = []
    var accumulator = 0
    var bits = 0
    for byte in bytes {
        accumulator = (accumulator << 8) | Int(byte)
        bits += 8
        while bits >= 11 {
            bits -= 11
            words.append(bip39EnglishWordlist[(accumulator >> bits) & 0x7FF])
        }
        accumulator &= (1 << bits) - 1
    }
    return words.joined(separator: " ")
}

private func decodePhrase(_ words: [String]) throws -> Data {
    var bytes: [UInt8] = []
    var accumulator = 0
    var bits = 0
    for word in words {
        guard let index = bip39Index[word] else {
            throw AccountError.invalidInput("\"\(word)\" is not a word in the recovery phrase list")
        }
        accumulator = (accumulator << 11) | index
        bits += 11
        while bits >= 8 {
            bits -= 8
            bytes.append(UInt8((accumulator >> bits) & 0xFF))
        }
        accumulator &= (1 << bits) - 1
    }
    // 24 × 11 = 264 bits: 32 bytes of entropy, then the checksum byte.
    let entropy = Data(bytes.prefix(entropyBytes))
    guard bytes.count == entropyBytes + 1, bytes[entropyBytes] == sha256(entropy)[0] else {
        throw AccountError.invalidInput("recovery phrase checksum failed — check for a mistyped or transposed word")
    }
    return entropy
}
