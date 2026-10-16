import Foundation

/// Something that produces Ed25519 signatures and names the key they verify
/// against — who signs, separated from what is signed.
///
/// Port of mero-js `signer/signer.ts`. Every signing entry point that takes a
/// root or device secret as hex also takes a `Signer`, so a key that must not
/// exist as a string — the account root in the Keychain
/// (``KeychainRootSigner``), a hardware token, a remote signing service — can
/// sign the same bytes without the SDK ever holding it.
///
/// Deliberately the smallest surface that works: the public key and a
/// signature. Anything larger would start describing *how* the key is held.
public protocol Signer: Sendable {
    /// The public half, 64 lowercase hex.
    ///
    /// Carried rather than derived on demand, because a key that cannot be
    /// exported cannot produce it later.
    var publicKey: String { get }

    /// Sign `payload` — the exact bytes, with no hashing or framing added.
    /// Returns a 64-byte Ed25519 signature.
    ///
    /// Every caller in MeroKit passes a 32-byte domain-separated digest it has
    /// already computed; an implementation that hashed again would produce
    /// signatures that verify nowhere.
    func sign(_ payload: Data) async throws -> Data
}

/// A ``Signer`` over a 32-byte Ed25519 seed held in memory.
///
/// The seed is private: nothing reads it back out of this value, so handing
/// a `SeedSigner` to other code hands it the ability to sign, not the key.
/// (== the signer mero-js `signerFromSecret` returns.)
public struct SeedSigner: Signer {
    public let publicKey: String
    private let seed: Data

    /// A signer over `seed` (32 bytes). The public half is derived from it,
    /// never accepted alongside it, so the two cannot disagree.
    public init(seed: Data, label: String = "secret") throws {
        guard seed.count == 32 else {
            throw AccountError.invalidInput("\(label) must be 64 hex characters, got \(seed.count * 2)")
        }
        self.seed = seed
        self.publicKey = Hex.encode(try Ed25519.publicKey(seed: seed))
    }

    public func sign(_ payload: Data) async throws -> Data {
        try Ed25519.sign(seed: seed, message: payload)
    }
}

/// A signer over a hex seed (64 hex). `label` names it in an error —
/// `deviceSecret`, `rootSecret`. (== mero-js `signerFromSecret`.)
public func signerFromSecret(_ secret: String, label: String = "secret") throws -> SeedSigner {
    try SeedSigner(seed: try Hex.decode(secret, label: label, bytes: 32), label: label)
}

/// The signer an input describes, from either form: a hex secret or a
/// ``Signer``. Exactly one must be present — both are refused, since they
/// could name different keys. (== mero-js `resolveSigner`.)
public func resolveSigner(_ secret: String?, _ signer: (any Signer)?, label: String) throws -> any Signer {
    if signer != nil, secret != nil {
        throw AccountError.invalidInput("pass either \(label) or signer, not both — they may name different keys")
    }
    if let signer { return signer }
    if let secret { return try signerFromSecret(secret, label: label) }
    throw AccountError.invalidInput("\(label) or signer is required")
}

/// Sign through `signer` and check the result is a 64-byte signature.
func signChecked(_ signer: any Signer, _ payload: Data) async throws -> Data {
    let signature = try await signer.sign(payload)
    guard signature.count == 64 else {
        throw AccountError.protocolViolation(
            "signer returned \(signature.count) bytes, expected a 64-byte Ed25519 signature")
    }
    return signature
}
