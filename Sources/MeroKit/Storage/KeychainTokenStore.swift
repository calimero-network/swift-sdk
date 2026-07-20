import Foundation

#if canImport(Security)
import Security

/// Keychain-backed token store — the secure default for shipping apps.
///
/// Stores the JSON-encoded ``TokenData`` as a single generic-password item.
/// Set `accessGroup` to a shared Keychain access-group so an SSO helper /
/// share / notification extension can read the same tokens (required for the
/// cross-process refresh coordination in the roadmap). Accessibility defaults to
/// `kSecAttrAccessibleAfterFirstUnlock` so a background extension can refresh.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let accessible: CFString

    public init(
        service: String = "network.calimero.merokit",
        account: String = "mero-tokens",
        accessGroup: String? = nil,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
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
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    public func getTokens() -> TokenData? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? MeroJSON.decode(TokenData.self, from: data)
    }

    public func setTokens(_ data: TokenData) {
        guard let encoded = try? MeroJSON.encode(data) else { return }

        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: accessible,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = encoded
            addQuery[kSecAttrAccessible as String] = accessible
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
#endif
