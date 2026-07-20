import Foundation

/// In-memory token store — the default. Not persisted across launches.
/// (== mero-js `MemoryTokenStore`.)
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenData?

    public init() {}

    public func getTokens() -> TokenData? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func setTokens(_ data: TokenData) {
        lock.lock(); defer { lock.unlock() }
        tokens = data
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}
