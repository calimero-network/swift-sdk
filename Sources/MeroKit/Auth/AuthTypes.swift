import Foundation

// Auth API types — ported 1:1 from mero-js `auth-api/auth-types.ts`.

// MARK: - Health and status

public struct HealthResponse: Codable, Sendable {
    public let status: String  // "alive" | "not_alive"
    public let storage: Bool
    public let uptimeSeconds: Int

    enum CodingKeys: String, CodingKey {
        case status, storage
        case uptimeSeconds = "uptime_seconds"
    }
}

public struct IdentityResponse: Codable, Sendable {
    public let service: String
    public let version: String
    public let authenticationMode: String
    public let providers: [String]

    enum CodingKeys: String, CodingKey {
        case service, version, providers
        case authenticationMode = "authentication_mode"
    }
}

public struct Provider: Codable, Sendable {
    public let name: String
    public let type: String
    public let description: String
    public let configured: Bool
    public let config: [String: JSONValue]
}

public struct ProvidersResponse: Codable, Sendable {
    public let providers: [Provider]
    public let count: Int
}

// MARK: - Authentication

/// Request body for `POST /auth/token`. (== mero-js `TokenRequest`.)
public struct TokenRequest: Codable, Sendable {
    public let authMethod: String
    public let publicKey: String
    public let clientName: String
    public let permissions: [String]?
    public let timestamp: Int
    public let providerData: [String: JSONValue]

    public init(
        authMethod: String, publicKey: String, clientName: String, permissions: [String]?, timestamp: Int,
        providerData: [String: JSONValue]
    ) {
        self.authMethod = authMethod
        self.publicKey = publicKey
        self.clientName = clientName
        self.permissions = permissions
        self.timestamp = timestamp
        self.providerData = providerData
    }

    enum CodingKeys: String, CodingKey {
        case authMethod = "auth_method"
        case publicKey = "public_key"
        case clientName = "client_name"
        case permissions, timestamp
        case providerData = "provider_data"
    }
}

/// The `{ data: { access_token, refresh_token } }` payload. (== mero-js `TokenResponse`.)
public struct TokenResponse: Codable, Sendable {
    public struct Payload: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case error
        }
    }
    public let data: Payload
    public let error: String?
}

public struct RefreshTokenRequest: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

/// Mock-token request (CI/testing). Core's shape is snake_case.
public struct MockTokenRequest: Codable, Sendable {
    public let clientName: String
    public let permissions: [String]?
    public let nodeUrl: String?
    public let accessTokenExpiry: Int?
    public let refreshTokenExpiry: Int?

    public init(
        clientName: String, permissions: [String]? = nil, nodeUrl: String? = nil, accessTokenExpiry: Int? = nil,
        refreshTokenExpiry: Int? = nil
    ) {
        self.clientName = clientName
        self.permissions = permissions
        self.nodeUrl = nodeUrl
        self.accessTokenExpiry = accessTokenExpiry
        self.refreshTokenExpiry = refreshTokenExpiry
    }

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case permissions
        case nodeUrl = "node_url"
        case accessTokenExpiry = "access_token_expiry"
        case refreshTokenExpiry = "refresh_token_expiry"
    }
}

// MARK: - Token management

/// Core revokes by `client_id`.
public struct RevokeTokenRequest: Codable, Sendable {
    public let clientId: String
    public init(clientId: String) { self.clientId = clientId }
    enum CodingKeys: String, CodingKey { case clientId = "client_id" }
}

public struct RevokeTokenResponse: Codable, Sendable {
    public let success: Bool
    public let message: String
}

// MARK: - Key management

public struct CreateKeyRequest: Codable, Sendable {
    public let publicKey: String
    public let authMethod: String
    public let providerData: [String: JSONValue]
    public let targetNodeUrl: String?

    public init(publicKey: String, authMethod: String, providerData: [String: JSONValue], targetNodeUrl: String? = nil)
    {
        self.publicKey = publicKey
        self.authMethod = authMethod
        self.providerData = providerData
        self.targetNodeUrl = targetNodeUrl
    }

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case authMethod = "auth_method"
        case providerData = "provider_data"
        case targetNodeUrl = "target_node_url"
    }
}

public struct CreateKeyResponse: Codable, Sendable {
    public let status: Bool
    public let message: String
}

public struct DeleteKeyResponse: Codable, Sendable {
    public let success: Bool
    public let message: String
}

/// A root key (core returns a flat array under `{ data }`).
public struct RootKey: Codable, Sendable {
    public let keyId: String
    public let publicKey: String
    public let authMethod: String
    public let createdAt: Int
    public let revokedAt: Int?
    public let permissions: [String]

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
        case authMethod = "auth_method"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case permissions
    }
}

/// A client key (core returns a flat array under `{ data }`).
public struct ClientKey: Codable, Sendable {
    public let clientId: String
    public let rootKeyId: String
    public let name: String
    public let permissions: [String]
    public let createdAt: Int
    public let revokedAt: Int?
    public let isValid: Bool

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case rootKeyId = "root_key_id"
        case name, permissions
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case isValid = "is_valid"
    }
}

public struct GenerateClientKeyRequest: Codable, Sendable {
    public let contextId: String?
    public let contextIdentity: String?
    public let permissions: [String]?
    public let targetNodeUrl: String?

    public init(
        contextId: String? = nil, contextIdentity: String? = nil, permissions: [String]? = nil,
        targetNodeUrl: String? = nil
    ) {
        self.contextId = contextId
        self.contextIdentity = contextIdentity
        self.permissions = permissions
        self.targetNodeUrl = targetNodeUrl
    }

    enum CodingKeys: String, CodingKey {
        case contextId = "context_id"
        case contextIdentity = "context_identity"
        case permissions
        case targetNodeUrl = "target_node_url"
    }
}

public struct DeleteClientResponse: Codable, Sendable {
    public let success: Bool
    public let message: String
}

// MARK: - Permissions

/// Core applies an `{ add, remove }` delta (remove first, then add) — NOT a
/// full-set replacement. A `permissions` field is ignored by core.
public struct UpdateKeyPermissionsRequest: Codable, Sendable {
    public let add: [String]?
    public let remove: [String]?

    public init(add: [String]? = nil, remove: [String]? = nil) {
        self.add = add
        self.remove = remove
    }
}

public struct PermissionResponse: Codable, Sendable {
    public struct Payload: Codable, Sendable {
        public let permissions: [String]
    }
    public let data: Payload
    public let error: String?
}

/// Result of a token validation. (== mero-js `validateToken` return.)
public struct TokenValidation: Sendable {
    public let valid: Bool
    public let status: Int
    public let headers: [String: String]
}
