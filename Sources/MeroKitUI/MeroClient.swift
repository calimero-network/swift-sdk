import Foundation
import MeroKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Observable frontend view-model wrapping ``Mero`` — the native analog of
/// mero-react's `MeroProvider` / `useMero`. Inject it via `.environmentObject`
/// and bind SwiftUI views to its `@Published` state.
///
/// Mobile sign-in is **Cloud only**: ``signInWithCloud(callbackScheme:)``
/// opens the Calimero wallet in the system auth sheet, the person approves
/// this device with their passkey, and the client connects to the relay that
/// serves their account. ``login(nodeURL:username:password:)`` remains for
/// talking to a development node directly; the shipped ``LoginView`` no
/// longer offers it.
///
/// A custom `URLSession` can be injected (used by UI tests to route through a
/// mock backend), mirroring the SDK's own testability hook.
@MainActor
public final class MeroClient: ObservableObject {
    @Published public private(set) var isAuthenticated = false
    @Published public private(set) var isLoading = false
    /// The node (or relay) this client talks to.
    @Published public private(set) var nodeURL: String = ""
    /// A display name: the username for a node login, a short account id for Cloud.
    @Published public private(set) var username: String = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastRpcResult: String?

    // MARK: Cloud session state

    /// The signed-in Cloud account (64 hex), or `nil`.
    @Published public private(set) var account: String?
    /// The relay serving the account, or `nil`.
    @Published public private(set) var relayURL: String?
    /// Signed in, but with no relay yet: a new account earns one by redeeming
    /// an invitation. Not an error.
    @Published public private(set) var isSignedInWithoutRelay = false
    /// Something worth showing about the Cloud session (relay choice, reads off).
    @Published public private(set) var cloudNote: String?
    /// The live relay connection, after a Cloud sign-in.
    public private(set) var connection: CloudConnection?

    private var mero: Mero?
    private let session: URLSession?
    private let makeTokenStore: @Sendable () -> any TokenStore
    private let cloud: CloudSignIn
    private let webAuthenticator: any WebAuthenticating

    public init(
        session: URLSession? = nil,
        tokenStore: @escaping @Sendable () -> any TokenStore = { MemoryTokenStore() },
        cloud: CloudSignIn? = nil,
        webAuthenticator: (any WebAuthenticating)? = nil
    ) {
        self.session = session
        self.makeTokenStore = tokenStore
        self.cloud =
            cloud
            ?? CloudSignIn(
                keyStore: Self.defaultKeyStore(), sessionStore: Self.defaultSessionStore(),
                urlSession: session ?? .shared)
        #if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
        self.webAuthenticator = webAuthenticator ?? SystemWebAuthenticator()
        #else
        self.webAuthenticator = webAuthenticator ?? UnavailableWebAuthenticator()
        #endif
    }

    // MARK: - Cloud sign-in

    /// Sign in with the Calimero wallet: open it in the system auth sheet with
    /// a callback on `callbackScheme` (e.g. `"mero-sample"` →
    /// `mero-sample://enrol`), verify what it returns, and connect to the
    /// account's relay. Publishes auth state or an error.
    public func signInWithCloud(callbackScheme: String) async {
        await signInWithCloud(callback: .scheme(callbackScheme))
    }

    /// As ``signInWithCloud(callbackScheme:)``, for any callback (an https
    /// Universal Link with `.https(host:path:)`).
    public func signInWithCloud(callback: CloudCallback) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let walletURL = try await cloud.beginEnrolment(callbackURL: callback.url)
            let returned = try await webAuthenticator.authenticate(url: walletURL, callback: callback)
            try await completeEnrolment(returned)
        } catch is WebAuthenticationCancelled {
            // Dismissing the sheet is a choice, not an error to show.
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Finish a sign-in from a callback URL the app received itself (an https
    /// Universal Link or `onOpenURL`), rather than through the auth sheet.
    /// Returns `false` when the URL carries no enrolment.
    @discardableResult
    public func handleEnrolmentCallback(_ url: URL) async -> Bool {
        guard (try? DeviceEnrolment.readCallback(url)) != nil || url.fragment?.contains("error=") == true else {
            return false
        }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await completeEnrolment(url)
        } catch {
            errorMessage = friendlyMessage(error)
        }
        return true
    }

    /// Reconnect the Cloud session from a previous launch, if any. Returns
    /// whether one was restored.
    @discardableResult
    public func restoreCloudSession() async -> Bool {
        guard let stored = await cloud.restoreSession() else { return false }
        isLoading = true
        defer { isLoading = false }
        await adopt(await cloud.connect(stored))
        return true
    }

    /// The account-layer client behind this view-model (joins, relay refresh).
    public var cloudSignIn: CloudSignIn { cloud }

    private func completeEnrolment(_ url: URL) async throws {
        let stored = try await cloud.completeEnrolment(callbackURL: url)
        await adopt(await cloud.connect(stored))
    }

    private func adopt(_ connection: CloudConnection) async {
        self.connection = connection
        self.mero = connection.mero
        account = connection.session.account
        relayURL = connection.session.relayUrl
        isSignedInWithoutRelay = connection.session.isRelayless
        cloudNote = connection.readNote ?? connection.session.note
        nodeURL = connection.session.relayUrl ?? ""
        username = Self.shortId(connection.session.account)
        isAuthenticated = true
    }

    // MARK: - Development node login

    /// Log in with username/password against `nodeURL` — a development node you
    /// run yourself. Not offered by ``LoginView``; mobile sign-in is Cloud.
    public func login(
        nodeURL nodeURLString: String, username: String, password: String
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
                Credentials(username: username, password: password))
            self.nodeURL = nodeURLString
            self.username = username
            self.isAuthenticated = true
        } catch {
            self.isAuthenticated = false
            self.errorMessage = friendlyMessage(error)
        }
    }

    // MARK: - Calls

    /// Run a sample contract call and publish its result (demo affordance).
    /// Over a Cloud session this reads through the relay (query, falling back
    /// to a warrant); over a node login it is a JSON-RPC call.
    public func runSampleRpc(contextId: String, method: String) async {
        errorMessage = nil
        do {
            if let relay = connection?.relay {
                let value = try await relay.query(contextId: contextId, method: method)
                lastRpcResult = "\(value ?? .null)"
            } else if let mero {
                let value: JSONValue = try await mero.rpc.execute(contextId: contextId, method: method)
                lastRpcResult = "\(value)"
            } else if isSignedInWithoutRelay {
                errorMessage = "No relay serves this account yet. Redeem an invitation to get one."
            }
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Sign out: retire the relay session and forget the account (the device
    /// key stays), or clear a node login.
    public func logout() async {
        if connection != nil {
            await cloud.signOut()
        }
        if let mero { await mero.logout() }
        mero = nil
        connection = nil
        account = nil
        relayURL = nil
        isSignedInWithoutRelay = false
        cloudNote = nil
        isAuthenticated = false
        username = ""
        nodeURL = ""
        lastRpcResult = nil
        errorMessage = nil
    }

    // MARK: - Helpers

    private func friendlyMessage(_ error: Error) -> String {
        switch error {
        case MeroError.authRevoked:
            return "Your session was revoked. Please sign in again."
        case MeroError.authenticationFailed:
            return "Login failed — check your credentials and node URL."
        case MeroError.network(let message):
            return "Can't reach Calimero: \(message)"
        case AccountError.enrolmentDeclined:
            return "This device was not approved. You can try again."
        case AccountError.stateMismatch:
            return "That sign-in did not come from this app. Please try again."
        case AccountError.credentialRejected:
            return "The wallet's answer could not be verified, so nothing was saved. Please try again."
        default:
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    static func shortId(_ id: String) -> String {
        id.count > 12 ? "\(id.prefix(6))…\(id.suffix(4))" : id
    }

    private static func defaultKeyStore() -> AnyValueStore<DeviceKeys> {
        #if canImport(Security)
        return .keychain(account: "cloud-device-keys")
        #else
        return .memory()
        #endif
    }

    private static func defaultSessionStore() -> AnyValueStore<CloudSession> {
        #if canImport(Security)
        return .keychain(account: "cloud-session")
        #else
        return .memory()
        #endif
    }
}

/// For platforms with no system auth sheet: always fails.
struct UnavailableWebAuthenticator: WebAuthenticating {
    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        throw AccountError.notSignedIn("no system web authentication on this platform")
    }
}
