import Foundation

/// A device certificate (`AccountProof<DeviceCert>`) read back apart, field by
/// field. Hex fields are lowercase.
///
/// Port of mero-js `src/device-cert/device-cert.ts`. The layout is core's
/// (`crates/account/src/{device,signed,account}.rs`):
///
/// ```
/// AccountProof { genesis: AccountGenesis, chain: Vec<RootKeyHandoff>, statement: DeviceCert }
///   AccountGenesis { version: u8, root_sign_pk: [u8; 32] }
///   chain          → u32-LE count (always 0 here)
///   DeviceCert     { account, device, sign_pk, kem_pk: [u8; 32] x4,
///                    key_epoch: u32, device_epoch: u32, signature: [u8; 64] }
/// ```
public struct DeviceCredential: Sendable, Equatable, Codable {
    /// The account root that signed (`AccountGenesis::root_sign_pk`).
    public let rootPublicKey: String
    /// The account the certificate names.
    public let account: String
    /// The device it certifies.
    public let device: String
    /// That device's Ed25519 signing key.
    public let signPublicKey: String
    /// That device's X25519 key-delivery key.
    public let kemPublicKey: String
    public let keyEpoch: UInt32
    public let deviceEpoch: UInt32
    /// The root's signature over ``DeviceCertificates/payload(account:device:signPublicKey:kemPublicKey:keyEpoch:deviceEpoch:)``.
    public let signature: String
}

/// Device-certificate primitives: parse, verify, and (for tests and tooling)
/// certify.
public enum DeviceCertificates {
    /// core's `ACCOUNT_GENESIS_VERSION`. Part of the account-id preimage, so a
    /// mismatch silently derives a different account.
    public static let accountGenesisVersion: UInt8 = 2
    /// Byte length of an `AccountProof<DeviceCert>` with an empty handoff chain.
    public static let credentialBytes = 237

    static let certDomain = "calimero.device.cert.v1"
    static let accountIdDomain = "calimero.account.genesis.v1"
    static let deviceIdDomain = "calimero.device.id.v1"

    /// The account a root owns: the content address of its genesis,
    /// `H(ACCOUNT_ID_DOMAIN, [version ‖ root_pk])`.
    public static func account(forRootPublicKey rootPublicKey: String) throws -> String {
        var genesis = Data([accountGenesisVersion])
        genesis.append(try Hex.decode(rootPublicKey, label: "rootPublicKey", bytes: 32))
        return Hex.encode(domainHash(accountIdDomain, [genesis]))
    }

    /// Mint a device id: `nonce ‖ H(DEVICE_ID_DOMAIN, [account, nonce])[..16]`.
    public static func mintDeviceId(account: String, nonce: Data) throws -> String {
        guard nonce.count == 16 else {
            throw AccountError.invalidInput("nonce must be 16 bytes, got \(nonce.count)")
        }
        let accountBytes = try Hex.decode(account, label: "account", bytes: 32)
        let binding = domainHash(deviceIdDomain, [accountBytes, nonce])
        return Hex.encode(nonce + binding.prefix(16))
    }

    /// The 32 bytes a root signs to certify a device. Both keys are covered.
    public static func payload(
        account: String, device: String, signPublicKey: String, kemPublicKey: String,
        keyEpoch: UInt32, deviceEpoch: UInt32
    ) throws -> Data {
        domainHash(
            certDomain,
            [
                try Hex.decode(account, label: "account", bytes: 32),
                try Hex.decode(device, label: "device", bytes: 32),
                try Hex.decode(signPublicKey, label: "signPublicKey", bytes: 32),
                try Hex.decode(kemPublicKey, label: "kemPublicKey", bytes: 32),
                LittleEndian.u32(keyEpoch),
                LittleEndian.u32(deviceEpoch),
            ])
    }

    /// Read a credential apart. Checks the **shape** only — see ``verify(_:)``.
    ///
    /// Throws on a wrong genesis version, a non-empty handoff chain (verifying
    /// it would mean walking the chain), or a wrong length.
    public static func parse(_ credential: String) throws -> DeviceCredential {
        let bytes = [UInt8](
            try Hex.decode(credential, label: "credential", bytes: credentialBytes))
        guard bytes[0] == accountGenesisVersion else {
            throw AccountError.credentialRejected(
                "this credential has account genesis version \(bytes[0]), not \(accountGenesisVersion) — it names a "
                    + "different account than its root key derives here, and core would refuse it")
        }
        let chainLength = u32(bytes, at: 33)
        guard chainLength == 0 else {
            throw AccountError.credentialRejected(
                "this credential carries a \(chainLength)-handoff root chain, which this SDK cannot verify yet")
        }
        func at(_ offset: Int, _ length: Int) -> String { Hex.encode(bytes[offset..<offset + length]) }
        return DeviceCredential(
            rootPublicKey: at(1, 32),
            account: at(37, 32),
            device: at(69, 32),
            signPublicKey: at(101, 32),
            kemPublicKey: at(133, 32),
            keyEpoch: u32(bytes, at: 165),
            deviceEpoch: u32(bytes, at: 169),
            signature: at(173, 64))
    }

    /// Check that a credential says what it claims: the account it names is
    /// the one its root derives, its device id was minted for that account, and
    /// the root signed it.
    ///
    /// What it does **not** establish is that the account is the one the
    /// caller wanted — anyone can mint a root offline. ``DeviceEnrolment``'s
    /// `state` and key binding close that.
    @discardableResult
    public static func verify(_ credential: String) throws -> DeviceCredential {
        let parsed = try parse(credential)

        let derived = try account(forRootPublicKey: parsed.rootPublicKey)
        guard derived == parsed.account else {
            throw AccountError.credentialRejected(
                "this credential names account \(parsed.account), but its root key derives \(derived) — the "
                    + "certificate was re-pointed at another account")
        }

        let nonce = try Hex.decode(parsed.device, label: "device", bytes: 32).prefix(16)
        guard try mintDeviceId(account: parsed.account, nonce: Data(nonce)) == parsed.device else {
            throw AccountError.credentialRejected(
                "this credential names device \(parsed.device), which was not minted for account "
                    + "\(parsed.account); core refuses it")
        }

        let message = try payload(
            account: parsed.account, device: parsed.device, signPublicKey: parsed.signPublicKey,
            kemPublicKey: parsed.kemPublicKey, keyEpoch: parsed.keyEpoch, deviceEpoch: parsed.deviceEpoch)
        guard
            Ed25519.verify(
                publicKey: try Hex.decode(parsed.rootPublicKey, label: "rootPublicKey", bytes: 32),
                signature: try Hex.decode(parsed.signature, label: "signature", bytes: 64),
                message: message)
        else {
            throw AccountError.credentialRejected(
                "the root key of account \(parsed.account) did not sign this certificate")
        }
        return parsed
    }

    /// Certify a device with a root seed — what a wallet does. Exposed for
    /// tests, fixtures and local tooling; an app never holds a root.
    public static func certify(
        rootSeed: Data, device: String, signPublicKey: String, kemPublicKey: String, deviceEpoch: UInt32 = 0
    ) throws -> String {
        let rootPublicKey = try Ed25519.publicKey(seed: rootSeed)
        let account = try account(forRootPublicKey: Hex.encode(rootPublicKey))
        let message = try payload(
            account: account, device: device, signPublicKey: signPublicKey, kemPublicKey: kemPublicKey,
            keyEpoch: 0, deviceEpoch: deviceEpoch)
        let signature = try Ed25519.sign(seed: rootSeed, message: message)

        var w = BorshWriter()
        w.u8(accountGenesisVersion)
        w.raw(rootPublicKey)
        w.u32(0)
        w.raw(try Hex.decode(account, label: "account", bytes: 32))
        w.raw(try Hex.decode(device, label: "device", bytes: 32))
        w.raw(try Hex.decode(signPublicKey, label: "signPublicKey", bytes: 32))
        w.raw(try Hex.decode(kemPublicKey, label: "kemPublicKey", bytes: 32))
        w.u32(0)
        w.u32(deviceEpoch)
        w.raw(signature)
        return Hex.encode(w.data)
    }

    private static func u32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
