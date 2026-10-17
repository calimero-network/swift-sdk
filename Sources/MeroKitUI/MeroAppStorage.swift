import Foundation

/// What a ``MeroClient`` remembers between launches, in `UserDefaults`: the
/// node, the node that minted the stored tokens, and the application, context
/// and context identity an SSO login named. Port of mero-react's `storage`
/// helpers (localStorage there); the keys are the same.
///
/// Tokens are not kept here: they live in the client's `TokenStore` (the
/// Keychain for a shipped app).
public final class MeroAppStorage: @unchecked Sendable {
    /// The keys, as mero-react names them.
    public enum Key: String, CaseIterable, Sendable {
        case nodeURL = "mero:node_url"
        /// The node the token bundle in the token store was issued by. Distinct
        /// from ``nodeURL``, which ``MeroClient/connectToNode(_:callback:)``
        /// points at the *target* node before the login page opens.
        case tokenNodeURL = "mero:token_node_url"
        case applicationId = "mero:application_id"
        case contextId = "mero:context_id"
        case contextIdentity = "mero:context_identity"
    }

    /// The standard defaults.
    public static let standard = MeroAppStorage()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Storage in a named suite, for tests and app groups.
    public convenience init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.init(defaults: defaults)
    }

    public func string(for key: Key) -> String? {
        let value = defaults.string(forKey: key.rawValue)
        return value?.isEmpty == true ? nil : value
    }

    /// Set, or clear with `nil`.
    public func store(_ value: String?, for key: Key) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    public var nodeURL: String? {
        get { string(for: .nodeURL) }
        set { store(newValue, for: .nodeURL) }
    }

    public var tokenNodeURL: String? {
        get { string(for: .tokenNodeURL) }
        set { store(newValue, for: .tokenNodeURL) }
    }

    public var applicationId: String? {
        get { string(for: .applicationId) }
        set { store(newValue, for: .applicationId) }
    }

    public var contextId: String? {
        get { string(for: .contextId) }
        set { store(newValue, for: .contextId) }
    }

    public var contextIdentity: String? {
        get { string(for: .contextIdentity) }
        set { store(newValue, for: .contextIdentity) }
    }

    /// Forget everything this stores. (== mero-react `clearAllStorage`.)
    public func clearAll() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    }
}
