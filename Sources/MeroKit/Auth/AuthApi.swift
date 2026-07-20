import Foundation

/// The auth service client. Ported 1:1 from mero-js `auth-api/auth-client.ts`.
public struct AuthApi: Sendable {
    let http: any HttpClient

    public init(http: any HttpClient) {
        self.http = http
    }

    // MARK: - Health and status

    public func getHealth() async throws -> HealthResponse {
        let resp: ApiResponse<HealthResponse> = try await http.get("/auth/health")
        guard let data = resp.data else { throw MeroError.emptyResponse("Health response data is null") }
        return data
    }

    public func getIdentity() async throws -> IdentityResponse {
        let resp: ApiResponse<IdentityResponse> = try await http.get("/admin/identity")
        guard let data = resp.data else { throw MeroError.emptyResponse("Identity response data is null") }
        return data
    }

    public func getProviders() async throws -> ProvidersResponse {
        let resp: ApiResponse<ProvidersResponse> = try await http.get("/auth/providers")
        guard let data = resp.data else { throw MeroError.emptyResponse("Providers response data is null") }
        return data
    }

    // MARK: - Authentication

    public func generateTokens(_ request: TokenRequest) async throws -> TokenResponse {
        try await http.post("/auth/token", json: request)
    }

    public func refreshToken(_ request: RefreshTokenRequest) async throws -> TokenResponse {
        try await http.post("/auth/refresh", json: request)
    }

    public func generateMockTokens(_ request: MockTokenRequest) async throws -> TokenResponse {
        try await http.post("/auth/mock-token", json: request)
    }

    /// Validate a token via `HEAD /auth/validate`. Never throws — maps failure to `valid: false`.
    public func validateToken(_ token: String) async -> TokenValidation {
        do {
            let head = try await http.head("/auth/validate", headers: ["Authorization": "Bearer \(token)"])
            return TokenValidation(valid: head.status == 200, status: head.status, headers: head.headers)
        } catch {
            return TokenValidation(valid: false, status: 401, headers: [:])
        }
    }

    // MARK: - Token management

    /// Revoke tokens. NOTE: node auth status lives on `AdminApi.isAuthed()`
    /// (`/admin-api/is-authed`); there is no `/auth/is-authed`.
    public func revokeTokens(_ request: RevokeTokenRequest) async throws -> RevokeTokenResponse {
        let resp: ApiResponse<RevokeTokenResponse> = try await http.post("/admin/revoke", json: request)
        guard let data = resp.data else { throw MeroError.emptyResponse("Revoke tokens response data is null") }
        return data
    }

    // MARK: - Key management

    public func listRootKeys() async throws -> [RootKey] {
        let resp: ApiResponse<[RootKey]> = try await http.get("/admin/keys")
        guard let data = resp.data else { throw MeroError.emptyResponse("Root keys response data is null") }
        return data
    }

    public func createRootKey(_ request: CreateKeyRequest) async throws -> CreateKeyResponse {
        let resp: ApiResponse<CreateKeyResponse> = try await http.post("/admin/keys", json: request)
        guard let data = resp.data else { throw MeroError.emptyResponse("Create root key response data is null") }
        return data
    }

    public func deleteRootKey(_ keyId: String) async throws -> DeleteKeyResponse {
        try await http.delete("/admin/keys/\(keyId)")
    }

    // MARK: - Client management

    public func listClientKeys() async throws -> [ClientKey] {
        let resp: ApiResponse<[ClientKey]> = try await http.get("/admin/keys/clients")
        guard let data = resp.data else { throw MeroError.emptyResponse("Client keys response data is null") }
        return data
    }

    public func generateClientKey(_ request: GenerateClientKeyRequest) async throws -> TokenResponse {
        try await http.post("/admin/client-key", json: request)
    }

    public func deleteClientKey(keyId: String, clientId: String) async throws -> DeleteClientResponse {
        try await http.delete("/admin/keys/\(keyId)/clients/\(clientId)")
    }

    // MARK: - Permissions

    public func getKeyPermissions(_ keyId: String) async throws -> PermissionResponse {
        try await http.get("/admin/keys/\(keyId)/permissions")
    }

    /// Core expects an `{ add, remove }` delta, not a `{ permissions }` replacement.
    public func updateKeyPermissions(
        _ keyId: String, changes: UpdateKeyPermissionsRequest
    ) async throws -> PermissionResponse {
        try await http.put("/admin/keys/\(keyId)/permissions", json: changes)
    }
}
