import Foundation
import MeroKit

/// What an app asks the node for at login, and so what its token may do.
/// (== mero-react `AppMode`.)
public enum AppMode: String, Sendable, CaseIterable {
    /// **Deprecated** (mero-react 2.1.0, removed in 3.0.0): the auth flow no
    /// longer selects a context for the app. Use ``multiContext`` and let the
    /// app pick its context itself.
    case singleContext = "single-context"
    /// The app manages its own contexts, namespaces, groups and blobs.
    case multiContext = "multi-context"
    /// Full administrative access.
    case admin

    /// The permission grants requested for the client token at login.
    /// (== mero-react `getPermissionsForMode`.)
    ///
    /// Cores since 0.11.0-rc.9 refuse admin routes a token holds no scope for.
    /// `context:subscribe` is what `/sse`, `/sse/subscription` and `/ws`
    /// require; without it every event stream answers `403 permission_denied`.
    /// `context:delete` is what `DELETE /admin-api/contexts/:id` requires.
    /// `context:list` is in every mode because an app reads
    /// `identities-owned` right after login.
    public var permissions: [String] {
        switch self {
        case .singleContext:
            return [
                "context:execute", "context:list", "context:subscribe", "application:list", "blob",
                "context:alias",
            ]
        case .multiContext:
            return [
                "context:create", "context:delete", "context:list", "context:execute", "context:subscribe",
                "application:list", "namespace", "group", "blob", "context:alias",
            ]
        case .admin:
            return ["admin"]
        }
    }
}

/// The permissions for `mode`. Public so whatever mints a token for an app on
/// its behalf tests against this rather than a hand copy.
/// (== mero-react `getPermissionsForMode`.)
public func permissions(for mode: AppMode) -> [String] {
    mode.permissions
}

/// What a connection may do, so an app asks *what is allowed* instead of which
/// transport it runs on. (== mero-react `MeroCapabilities`.)
public struct MeroCapabilities: Sendable, Equatable {
    /// Found a namespace.
    public let createNamespace: Bool
    /// Create a context inside a namespace this connection belongs to.
    public let createContext: Bool
    /// Mint an invitation to a namespace.
    public let invite: Bool
    /// Upgrade a group's application. A node's only.
    public let upgrade: Bool

    public init(createNamespace: Bool, createContext: Bool, invite: Bool, upgrade: Bool) {
        self.createNamespace = createNamespace
        self.createContext = createContext
        self.invite = invite
        self.upgrade = upgrade
    }

    /// A node login can do everything.
    public static let node = MeroCapabilities(createNamespace: true, createContext: true, invite: true, upgrade: true)

    /// An account on a relay: it founds a namespace only when the app names its
    /// registry package (the founding names the application), signs its own
    /// invitations, and cannot upgrade (only a group's first application choice
    /// goes through a relay).
    public static func account(hasPackage: Bool) -> MeroCapabilities {
        MeroCapabilities(createNamespace: hasPackage, createContext: true, invite: true, upgrade: false)
    }

    /// Nothing, before any connection.
    public static let none = MeroCapabilities(
        createNamespace: false, createContext: false, invite: false, upgrade: false)
}

/// How a ``MeroClient`` is configured. (== mero-react `MeroProviderConfig`.)
public struct MeroProviderConfig: Sendable, Equatable {
    public var mode: AppMode
    /// The app's registry package (an account founds namespaces for it).
    public var packageName: String?
    /// The version to pin; the registry's latest when `nil`.
    public var packageVersion: String?
    /// The registry the package is published on.
    public var registryURL: String?
    /// The cloud an account asks for routing; the hosted one when `nil`.
    public var cloudBaseURL: URL?
    /// Origins an SSO callback may authenticate against besides the node the
    /// login was started with (see ``NodeTrust``).
    public var allowedNodeURLs: [String]
    /// Request timeout for node clients.
    public var timeout: TimeInterval

    public init(
        mode: AppMode = .multiContext, packageName: String? = nil, packageVersion: String? = nil,
        registryURL: String? = nil, cloudBaseURL: URL? = nil, allowedNodeURLs: [String] = [], timeout: TimeInterval = 30
    ) {
        self.mode = mode
        self.packageName = packageName
        self.packageVersion = packageVersion
        self.registryURL = registryURL
        self.cloudBaseURL = cloudBaseURL
        self.allowedNodeURLs = allowedNodeURLs
        self.timeout = timeout
    }

    /// The app's registry identity, as the admins take it.
    public var app: AdminAppConfig {
        AdminAppConfig(packageName: packageName, packageVersion: packageVersion, registryURL: registryURL)
    }
}
