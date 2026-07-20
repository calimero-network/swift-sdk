import Foundation
import MeroKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Observable frontend view-model wrapping ``Mero`` — the native analog of
/// mero-react's `MeroProvider` / `useMero`. Inject it via `.environmentObject`
/// and bind SwiftUI views to its `@Published` state.
///
/// A custom `URLSession` can be injected (used by UI tests to route through a
/// mock backend), mirroring the SDK's own testability hook.
@MainActor
public final class MeroClient: ObservableObject {
    @Published public private(set) var isAuthenticated = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var nodeURL: String = ""
    @Published public private(set) var username: String = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastRpcResult: String?

    private var mero: Mero?
    private let session: URLSession?
    private let makeTokenStore: @Sendable () -> any TokenStore

    public init(
        session: URLSession? = nil,
        tokenStore: @escaping @Sendable () -> any TokenStore = { MemoryTokenStore() }
    ) {
        self.session = session
        self.makeTokenStore = tokenStore
    }

    /// Log in with username/password against `nodeURL`. Publishes auth state or an error.
    public func login(
        nodeURL nodeURLString: String, username: String, password: String, bootstrapSecret: String? = nil
    ) async {
        errorMessage = nil

        guard let url = URL(string: nodeURLString), url.scheme != nil else {
            errorMessage = "Enter a valid node URL (e.g. http://localhost:4001)."
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Username and password are required."
            return
        }

        isLoading = true
        defer { isLoading = false }

        let config = MeroConfig(baseURL: url, tokenStore: makeTokenStore())
        let client = session.map { Mero(config: config, session: $0) } ?? Mero(config: config)
        self.mero = client

        do {
            _ = try await client.authenticate(
                Credentials(username: username, password: password, bootstrapSecret: bootstrapSecret)
            )
            self.nodeURL = nodeURLString
            self.username = username
            self.isAuthenticated = true
        } catch {
            self.isAuthenticated = false
            self.errorMessage = friendlyMessage(error)
        }
    }

    /// Run a sample contract call and publish its result (demo affordance).
    public func runSampleRpc(contextId: String, method: String) async {
        guard let mero else { return }
        errorMessage = nil
        do {
            let value: JSONValue = try await mero.rpc.execute(contextId: contextId, method: method)
            lastRpcResult = "\(value)"
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Clear the session locally.
    public func logout() async {
        if let mero { await mero.logout() }
        mero = nil
        isAuthenticated = false
        username = ""
        lastRpcResult = nil
        errorMessage = nil
    }

    private func friendlyMessage(_ error: Error) -> String {
        switch error {
        case MeroError.authRevoked:
            return "Your session was revoked. Please sign in again."
        case MeroError.authenticationFailed:
            return "Login failed — check your credentials and node URL."
        case MeroError.network(let message):
            return "Can't reach the node: \(message)"
        default:
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }
}
