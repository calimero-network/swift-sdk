import Foundation

// Scoping a device offline: which applications a device of an account may
// speak for, signed by the account root.
//
// Port of mero-js `src/device-cert/device-scope.ts`. The certificate says
// *this key is a device of the account*; the scope says where. A namespace
// binds a device only when both arrive together. A node that pairs a device
// signs the scope itself (``AdminApi/rescopeDevice(_:request:)`` runs on the
// node holding the root, and takes no signature); an account with **no node**
// signs it here and hands both to ``AdminApi/linkAccountDevice(_:request:)``.
//
// Derived from core `DeviceScope::signing_payload` (`crates/account/src/scope.rs`)
// and `DEVICE_SCOPE_SIGN_DOMAIN`; `DeviceScopeTests` pins core's vectors.

/// What a root scopes one device to.
public struct DeviceScopeInput: Sendable {
    /// The account root's signing secret, 64 hex. Pass this or ``signer``.
    public var rootSecret: String?
    /// The account root as a ``Signer``. Its `publicKey` is the genesis key the
    /// proof carries, and the account is derived from it.
    public var signer: (any Signer)?
    /// The device being scoped, 64 hex — the one its certificate names.
    public var device: String
    /// Application ids the device may speak for, 64 hex each. **Empty means
    /// all of them.** A scope naming the wrong application is a relay `400`.
    public var applications: [String]
    /// Orders scopes for this device: only a higher one supersedes. 0 for a
    /// device's first scope.
    public var scopeEpoch: UInt32

    public init(
        rootSecret: String? = nil, signer: (any Signer)? = nil, device: String, applications: [String] = [],
        scopeEpoch: UInt32 = 0
    ) {
        self.rootSecret = rootSecret
        self.signer = signer
        self.device = device
        self.applications = applications
        self.scopeEpoch = scopeEpoch
    }
}

/// core's `DEVICE_SCOPE_SIGN_DOMAIN`.
let deviceScopeDomain = "calimero.device.scope.v1"

/// The 32 bytes a root signs to scope a device: `domain_hash` over account,
/// device, `scope_epoch` (u32 LE), `key_epoch` (u32 LE), then each application
/// id as its own length-prefixed part.
public func deviceScopePayload(
    account: String, device: String, applications: [String], scopeEpoch: UInt32, keyEpoch: UInt32
) throws -> Data {
    var parts = [
        try Hex.decode(account, label: "account", bytes: 32),
        try Hex.decode(device, label: "device", bytes: 32),
        LittleEndian.u32(scopeEpoch),
        LittleEndian.u32(keyEpoch),
    ]
    for (i, application) in applications.enumerated() {
        parts.append(try Hex.decode(application, label: "applications[\(i)]", bytes: 32))
    }
    return domainHash(deviceScopeDomain, parts)
}

/// Scope a device, returning the hex `AccountProof<DeviceScope>` that
/// ``LinkAccountDeviceRequest/scope`` takes beside the credential.
///
/// ```
/// AccountProof { genesis: AccountGenesis, chain: Vec<RootKeyHandoff>, statement: DeviceScope }
///   AccountGenesis { version: u8, root_sign_pk: [u8; 32] }
///   chain          → u32-LE count (0 here)
///   DeviceScope    { account, device: [u8; 32] x2, applications: Vec<[u8; 32]>,
///                    scope_epoch: u32, key_epoch: u32, signature: [u8; 64] }
/// ```
///
/// The chain is empty and `key_epoch` 0: a root never handed off signs directly.
public func signDeviceScope(_ input: DeviceScopeInput) async throws -> String {
    let signer = try resolveSigner(input.rootSecret, input.signer, label: "rootSecret")
    let rootPublicKey = try Hex.decode(signer.publicKey, label: "signer.publicKey", bytes: 32)
    let account = try DeviceCertificates.account(forRootPublicKey: signer.publicKey)
    let keyEpoch: UInt32 = 0

    let payload = try deviceScopePayload(
        account: account, device: input.device, applications: input.applications, scopeEpoch: input.scopeEpoch,
        keyEpoch: keyEpoch)
    let signature = try await signChecked(signer, payload)

    var w = BorshWriter()
    w.u8(DeviceCertificates.accountGenesisVersion)
    w.raw(rootPublicKey)
    w.u32(0)
    w.raw(try Hex.decode(account, label: "account", bytes: 32))
    w.raw(try Hex.decode(input.device, label: "device", bytes: 32))
    w.u32(UInt32(input.applications.count))
    for (i, application) in input.applications.enumerated() {
        w.raw(try Hex.decode(application, label: "applications[\(i)]", bytes: 32))
    }
    w.u32(input.scopeEpoch)
    w.u32(keyEpoch)
    w.raw(signature)
    return Hex.encode(w.data)
}
