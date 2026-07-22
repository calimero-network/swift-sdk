import Foundation
import MeroKit

/// Holds the authenticated `Mero` client for the explorer and drives login/logout.
/// Unlike the mock-only `MeroClient`, this talks to a real node.
@MainActor
final class MeroSession: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published var nodeURL = "http://localhost:4001"
    @Published var username = ""
    @Published var errorMessage: String?
    /// A short human-readable identity/health summary shown on the explorer header.
    @Published var nodeSummary = ""

    private(set) var mero: Mero?

    func login(nodeURL nodeURLString: String, username: String, password: String) async {
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

        let client = Mero(config: MeroConfig(baseURL: url, tokenStore: MemoryTokenStore()))
        do {
            _ = try await client.authenticate(Credentials(username: username, password: password))
            self.mero = client
            self.nodeURL = nodeURLString
            self.username = username
            self.isAuthenticated = true
            await refreshSummary()
        } catch {
            self.isAuthenticated = false
            self.errorMessage = friendly(error)
        }
    }

    func logout() async {
        if let mero { await mero.logout() }
        mero = nil
        isAuthenticated = false
        nodeSummary = ""
    }

    private func refreshSummary() async {
        guard let mero else { return }
        do {
            let id = try await mero.auth.getIdentity()
            let peers = try? await mero.admin.getPeersCount()
            var line = "\(id.service) · \(id.version) · \(id.authenticationMode)"
            if let peers { line += " · \(peers.count) peers" }
            nodeSummary = line
        } catch {
            nodeSummary = "connected"
        }
    }

    private func friendly(_ error: Error) -> String {
        switch error {
        case MeroError.authRevoked: return "Session revoked — sign in again."
        case MeroError.authenticationFailed: return "Login failed — check credentials and node URL."
        case MeroError.network(let m): return "Can't reach the node: \(m)"
        default: return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
