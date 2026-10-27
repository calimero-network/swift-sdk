import Foundation

#if canImport(Security)
import Security

/// Keychain-backed token store — the secure default for shipping apps.
///
/// Stores the JSON-encoded ``TokenData`` as a single generic-password item.
/// Set `accessGroup` to a shared Keychain access-group so an SSO helper /
/// share / notification extension can read the same tokens (required for the
/// cross-process refresh coordination in the roadmap). Accessibility defaults to
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: a background extension
/// can still refresh, and the tokens never travel in a backup or a device
/// migration to a device that does not hold the keys they pair with. An item
/// saved under an older class moves to this one on its next write.
///
/// A write that fails (the device locked, say) is counted in ``writeFailures``
/// and handed to `onWriteFailure`, not dropped.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let item: KeychainItem
    private let accessible: CFString
    /// Failed writes, for diagnostics.
    public let writeFailures: KeychainWriteFailures

    public init(
        service: String = "network.calimero.merokit",
        account: String = "mero-tokens",
        accessGroup: String? = nil,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        onWriteFailure: (@Sendable (OSStatus) -> Void)? = nil
    ) {
        self.item = KeychainItem(service: service, account: account, accessGroup: accessGroup)
        self.accessible = accessible
        self.writeFailures = KeychainWriteFailures(onFailure: onWriteFailure)
    }

    public func getTokens() -> TokenData? {
        item.read().flatMap { try? MeroJSON.decode(TokenData.self, from: $0) }
    }

    public func setTokens(_ data: TokenData) {
        guard let encoded = try? MeroJSON.encode(data) else { return }
        writeFailures.record(item.write(encoded, accessible: accessible))
    }

    public func clear() {
        writeFailures.record(item.delete())
    }
}
#endif
