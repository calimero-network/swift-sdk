import Foundation
import MeroKit
import MeroKitUI

/// The explorer's session: Cloud sign-in (wallet passkey → device certificate
/// → hosted relay), the live relay connection, and a diagnostics log.
///
/// There is no node URL and no password in the UI. The one exception is the
/// development hook for the real-node e2e harnesses: launched with `E2E_NODE`,
/// `E2E_NODE_USER` and `E2E_NODE_PASS` in the environment, the app signs in to
/// that node directly at launch. Nothing in the UI exposes it.
@MainActor
final class MeroSession: ObservableObject {
    struct LogLine: Identifiable {
        enum Level {
            case info, ok, warn, err, req

            /// SF Symbol for the level (no glyphs in the UI).
            var symbol: String {
                switch self {
                case .info: return "circle.fill"
                case .ok: return "checkmark.circle"
                case .warn: return "exclamationmark.triangle"
                case .err: return "xmark.circle"
                case .req: return "arrow.right"
                }
            }

            var tag: String {
                switch self {
                case .info: return "info"
                case .ok: return "ok"
                case .warn: return "warn"
                case .err: return "error"
                case .req: return "req"
                }
            }
        }

        let id = UUID()
        let time: Date
        let level: Level
        let text: String
    }

    static let callbackScheme = "mero-sample"

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// The signed-in account, 64 hex.
    @Published private(set) var account: String?
    /// The relay serving it, or nil (signed in without a relay).
    @Published private(set) var relayURL: String?
    /// A note about the relay or reads, to show as a callout.
    @Published private(set) var note: String?
    /// The development node, when signed in through the e2e hook.
    @Published private(set) var devNodeURL: String?
    @Published private(set) var logs: [LogLine] = []
    /// One chat service for the whole session.
    @Published private(set) var chat: ChatService?

    private(set) var connection: CloudConnection?
    private var devMero: Mero?
    let signIn: CloudSignIn
    private let web: any WebAuthenticating
    private let urlSession: URLSession

    /// The `Mero` for admin calls: the relay's Bearer session, or the dev node.
    var mero: Mero? { connection?.mero ?? devMero }
    var relay: RelayClient? { connection?.relay }

    /// A display name for chat and the header.
    var displayName: String {
        if let name = ProcessInfo.processInfo.environment["E2E_USERNAME"], !name.isEmpty { return name }
        if let account { return "Account \(account.prefix(6))" }
        return devMero == nil ? "" : "dev"
    }

    init(signIn: CloudSignIn, web: any WebAuthenticating, urlSession: URLSession = .shared) {
        self.signIn = signIn
        self.web = web
        self.urlSession = urlSession
    }

    private static let ts: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ level: LogLine.Level, _ text: String) {
        logs.append(LogLine(time: Date(), level: level, text: text))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        print("[MeroKit] \(Self.ts.string(from: Date())) \(level.tag) \(text)")
    }

    func clearLogs() { logs.removeAll() }

    func logText() -> String {
        logs.map { "\(Self.ts.string(from: $0.time)) [\($0.level.tag)] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Launch

    /// Restore a previous Cloud session, or use the e2e dev-node hook.
    func start() async {
        let env = ProcessInfo.processInfo.environment
        if let node = env["E2E_NODE"], !node.isEmpty, let user = env["E2E_NODE_USER"], let pass = env["E2E_NODE_PASS"] {
            await connectDevelopmentNode(node, username: user, password: pass)
            return
        }
        guard let stored = await signIn.restoreSession() else { return }
        log(.info, "restoring Cloud session for \(stored.account.prefix(12))…")
        isLoading = true
        defer { isLoading = false }
        adopt(await signIn.connect(stored))
    }

    // MARK: - Cloud sign-in

    func signInWithCloud() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let callback = CloudCallback.scheme(Self.callbackScheme)
        do {
            let walletURL = try await signIn.beginEnrolment(callbackURL: callback.url)
            log(.req, "opening wallet \(walletURL.host ?? "")")
            let returned = try await web.authenticate(url: walletURL, callback: callback)
            try await complete(returned)
        } catch is WebAuthenticationCancelled {
            log(.info, "sign-in sheet dismissed")
        } catch {
            errorMessage = friendly(error)
            log(.err, "sign-in failed: \(detail(error))")
        }
    }

    /// A callback delivered to the app itself (`onOpenURL`).
    func handleCallback(_ url: URL) async {
        guard url.scheme == Self.callbackScheme else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await complete(url)
        } catch {
            errorMessage = friendly(error)
            log(.err, "callback refused: \(detail(error))")
        }
    }

    private func complete(_ url: URL) async throws {
        let session = try await signIn.completeEnrolment(callbackURL: url)
        log(.ok, "device certified for account \(session.account.prefix(12))…")
        log(.info, session.relayUrl.map { "relay: \($0)" } ?? "no relay yet")
        adopt(await signIn.connect(session))
    }

    private func adopt(_ connection: CloudConnection) {
        self.connection = connection
        account = connection.session.account
        relayURL = connection.session.relayUrl
        note = connection.readNote ?? connection.session.note
        if let readNote = connection.readNote { log(.warn, readNote) }
        if connection.mero != nil { log(.ok, "relay session established") }
        chat = ChatService(backend: .relay(connection, signIn), username: displayName)
        isAuthenticated = true
    }

    /// Re-connect after the session changed (a join adopted a relay).
    func reconnect() async {
        guard let stored = await signIn.restoreSession() else { return }
        adopt(await signIn.connect(stored))
    }

    // MARK: - Development node (e2e hook only)

    private func connectDevelopmentNode(_ urlString: String, username: String, password: String) async {
        guard let url = URL(string: urlString) else { return }
        isLoading = true
        defer { isLoading = false }
        log(.req, "development node \(urlString)")
        let client = Mero(config: MeroConfig(baseURL: url, tokenStore: MemoryTokenStore()), session: urlSession)
        do {
            _ = try await client.authenticate(Credentials(username: username, password: password))
            devMero = client
            devNodeURL = urlString
            chat = ChatService(backend: .node(client), username: displayName)
            isAuthenticated = true
            log(.ok, "authenticated on the development node")
        } catch {
            errorMessage = friendly(error)
            log(.err, "development node login failed: \(detail(error))")
        }
    }

    // MARK: - Sign out

    func logout() async {
        log(.req, "sign out")
        if connection != nil { await signIn.signOut() }
        if let devMero { await devMero.logout() }
        connection = nil
        devMero = nil
        devNodeURL = nil
        account = nil
        relayURL = nil
        note = nil
        chat = nil
        isAuthenticated = false
        log(.ok, "signed out")
    }

    // MARK: - Messages

    private func friendly(_ error: Error) -> String {
        switch error {
        case AccountError.enrolmentDeclined: return "This device was not approved. You can try again."
        case AccountError.stateMismatch: return "That sign-in did not come from this app. Please try again."
        case AccountError.credentialRejected:
            return "The wallet's answer could not be verified, so nothing was saved."
        case MeroError.network(let m): return "Can't reach Calimero: \(m)"
        default: return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    private func detail(_ error: Error) -> String {
        if let u = error as? URLError { return "URLError \(u.errorCode) url=\(u.failingURL?.absoluteString ?? "")" }
        return String(reflecting: error)
    }
}
