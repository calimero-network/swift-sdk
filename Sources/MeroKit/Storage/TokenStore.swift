import Foundation

/// Persistence for the token bundle. (== mero-js `TokenStore` interface.)
///
/// Methods are synchronous and must be safe to call from any thread — the
/// ``Mero`` actor and any auth helper/extension may touch the same store.
public protocol TokenStore: Sendable {
    func getTokens() -> TokenData?
    func setTokens(_ data: TokenData)
    func clear()
}
