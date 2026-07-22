import Foundation
import MeroKit

/// Holds the authenticated `Mero` client for the explorer, drives login/logout,
/// and keeps a diagnostics log so connection/auth problems are debuggable in-app.
@MainActor
final class MeroSession: ObservableObject {
    struct LogLine: Identifiable {
        enum Level: String { case info = "•", ok = "✓", warn = "!", err = "✗", req = "→" }
        let id = UUID()
        let time: Date
        let level: Level
        let text: String
    }

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published var nodeURL = "http://localhost:4001"
    @Published var username = ""
    @Published var errorMessage: String?
    @Published private(set) var nodeSummary = ""
    @Published private(set) var logs: [LogLine] = []

    private(set) var mero: Mero?
    private let sso = SsoWebLogin()
    private let callbackScheme = "merokit"

    private static let ts: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func log(_ level: LogLine.Level, _ text: String) {
        logs.append(LogLine(time: Date(), level: level, text: text))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        // Also emit to stdout so logs are readable via Xcode console or
        // `xcrun simctl launch --console-pty`, outside the app.
        print("[MeroKit] \(Self.ts.string(from: Date())) \(level.rawValue) \(text)")
    }

    func clearLogs() { logs.removeAll() }

    /// The whole log as copy-pasteable text.
    func logText() -> String {
        logs.map { "\(Self.ts.string(from: $0.time)) \($0.level.rawValue) \($0.text)" }.joined(separator: "\n")
    }

    /// Hosted-SSO login: open the node's `/auth/login` page (admin mode), let the
    /// user authenticate there, and adopt the tokens from the callback fragment —
    /// the same redirect flow mero-chat/mero-react use, via ASWebAuthenticationSession.
    func connect(nodeURL nodeURLString: String) async {
        errorMessage = nil
        log(.req, "SSO connect \(nodeURLString)")
        guard let base = URL(string: nodeURLString), base.scheme != nil else {
            errorMessage = "Enter a valid node URL (e.g. http://localhost:4001)."
            log(.err, "invalid node URL")
            return
        }
        isLoading = true
        defer { isLoading = false }

        let loginURLString = Mero.buildAuthLoginUrl(
            nodeUrl: nodeURLString,
            options: AuthLoginOptions(
                callbackUrl: "\(callbackScheme)://auth-callback", mode: "admin", permissions: ["admin"]))
        log(.info, "opening \(loginURLString)")
        guard let loginURL = URL(string: loginURLString) else {
            errorMessage = "Could not build the login URL."
            log(.err, "bad login URL")
            return
        }
        do {
            let callback = try await sso.authenticate(loginURL: loginURL, callbackScheme: callbackScheme)
            log(.info, "callback received (\(callback.absoluteString.prefix(60))…)")
            guard let result = Mero.parseAuthCallback(callback.absoluteString) else {
                errorMessage = "The login page returned no tokens."
                log(.err, "no access_token in callback fragment")
                return
            }
            let client = Mero(config: MeroConfig(baseURL: base, tokenStore: MemoryTokenStore()))
            await client.setTokenData(from: result)
            self.mero = client
            self.nodeURL = nodeURLString
            self.username = "admin"
            self.isAuthenticated = true
            log(.ok, "authenticated via SSO — tokens adopted")
            await refreshSummary()
        } catch {
            isAuthenticated = false
            errorMessage = friendly(error)
            log(.err, "SSO login failed — \(detail(error))")
        }
    }

    func login(nodeURL nodeURLString: String, username: String, password: String) async {
        errorMessage = nil
        log(.req, "connect \(nodeURLString) as “\(username.isEmpty ? "<empty>" : username)”")
        guard let url = URL(string: nodeURLString), url.scheme != nil else {
            errorMessage = "Enter a valid node URL (e.g. http://localhost:4001)."
            log(.err, "invalid node URL")
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Username and password are required."
            log(.warn, "missing username or password — nothing sent")
            return
        }
        isLoading = true
        defer { isLoading = false }

        let client = Mero(config: MeroConfig(baseURL: url, tokenStore: MemoryTokenStore()))
        do {
            log(.info, "POST \(url.absoluteString)/auth/token …")
            _ = try await client.authenticate(Credentials(username: username, password: password))
            self.mero = client
            self.nodeURL = nodeURLString
            self.username = username
            self.isAuthenticated = true
            log(.ok, "authenticated — token acquired")
            await refreshSummary()
        } catch {
            self.isAuthenticated = false
            self.errorMessage = friendly(error)
            log(.err, "login failed — \(detail(error))")
        }
    }

    func logout() async {
        log(.req, "logout")
        if let mero { await mero.logout() }
        mero = nil
        isAuthenticated = false
        nodeSummary = ""
        log(.ok, "signed out")
    }

    private func refreshSummary() async {
        guard let mero else { return }
        do {
            let id = try await mero.auth.getIdentity()
            let peers = try? await mero.admin.getPeersCount()
            var line = "\(id.service) · \(id.version) · \(id.authenticationMode)"
            if let peers { line += " · \(peers.count) peers" }
            nodeSummary = line
            log(.info, "identity: \(line)")
        } catch {
            nodeSummary = "connected"
            log(.warn, "identity fetch failed — \(detail(error))")
        }
    }

    /// Short, user-facing message.
    private func friendly(_ error: Error) -> String {
        switch error {
        case MeroError.authRevoked: return "Session revoked — sign in again."
        case MeroError.authenticationFailed: return "Login failed — check your username and password."
        case MeroError.network(let m): return "Can't reach the node: \(m)"
        default:
            if let u = error as? URLError { return "Can't reach the node (\(u.code))." }
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    /// Verbose one-line detail for the diagnostics log — distinguishes a
    /// connectivity failure (URLError) from an auth rejection, with the URL.
    private func detail(_ error: Error) -> String {
        if let u = error as? URLError {
            return "URLError \(u.errorCode) (\(u.code)) url=\(u.failingURL?.absoluteString ?? nodeURL)"
        }
        return String(reflecting: error)
    }
}
