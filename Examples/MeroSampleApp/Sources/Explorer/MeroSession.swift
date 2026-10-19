import Foundation
import MeroKit
import MeroKitUI

/// The explorer's session: Cloud sign-in (wallet passkey → device certificate
/// → hosted relay), or a node you run yourself (URL + admin username and
/// password), plus a diagnostics log.
///
/// Cloud is the default. "Manually enter node URL" on the sign-in screen signs
/// in to a node directly — a local `merod`, say — with no Cloud account. The
/// real-node e2e harnesses use the same path at launch through `E2E_NODE`,
/// `E2E_NODE_USER` and `E2E_NODE_PASS`.
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
    /// The node, when signed in to one directly rather than through Cloud.
    @Published private(set) var devNodeURL: String?
    /// The node URL and username last used, prefilled on the sign-in screen.
    /// The password is never stored.
    @Published var lastNodeURL: String = UserDefaults.standard.string(forKey: "lastNodeURL") ?? "http://localhost:4001"
    @Published var lastNodeUser: String = UserDefaults.standard.string(forKey: "lastNodeUser") ?? "dev"
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
        return devMero == nil ? "" : lastNodeUser
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
            await connectNode(node, username: user, password: pass)
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

    // MARK: - A node, signed in to directly

    /// Sign in to a node with its admin username and password.
    func connectNode(_ rawURL: String, username: String, password: String) async {
        errorMessage = nil
        let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            errorMessage = "Enter a full node URL, like http://localhost:4001."
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter the node's admin username and password."
            return
        }
        lastNodeURL = urlString
        lastNodeUser = username
        UserDefaults.standard.set(urlString, forKey: "lastNodeURL")
        UserDefaults.standard.set(username, forKey: "lastNodeUser")
        isLoading = true
        defer { isLoading = false }
        log(.req, "node \(urlString)")
        let client = Mero(config: MeroConfig(baseURL: url, tokenStore: MemoryTokenStore()), session: urlSession)
        do {
            _ = try await client.authenticate(Credentials(username: username, password: password))
            devMero = client
            devNodeURL = urlString
            chat = ChatService(backend: .node(client), username: displayName)
            isAuthenticated = true
            log(.ok, "authenticated on the node")
        } catch MeroError.network {
            errorMessage = "Can't reach a node at \(urlString). Is merod running?"
            log(.err, "node unreachable: \(urlString)")
        } catch {
            errorMessage = friendly(error)
            log(.err, "node login failed: \(detail(error))")
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
        case MeroError.authenticationFailed: return "The node refused that username or password."
        default: return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    private func detail(_ error: Error) -> String {
        if let u = error as? URLError { return "URLError \(u.errorCode) url=\(u.failingURL?.absoluteString ?? "")" }
        return String(reflecting: error)
    }
}
