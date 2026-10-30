import Foundation
import MeroKit

#if canImport(Combine)
import Combine
#endif

/// How a ``MeroClient`` reaches its cluster. (== mero-react `MeroProviderConfig`.)
public struct MeroProviderConfig: Sendable {
    /// A node of the cluster the app talks to (from Calimero Cloud's console).
    /// `nil` falls back to ``cloudBaseURL``; with neither, sign-in asks for one
    /// (``MeroClient/connect(nodeURL:nodes:allowMock:)``).
    public var nodeURL: String?
    /// Other nodes of the same cluster, to move to on `421 WRONG_NODE`.
    public var nodes: [String]
    /// What the client trusts the node to be: ``CloudPolicy/production`` by default.
    public var policy: CloudPolicy
    /// The app's package (`com.example.app`): what an org is founded for and
    /// an app instance created from.
    public var packageName: String?
    /// The version new app instances run; the latest when `nil`.
    public var packageVersion: String?
    /// The pre-1.0 Cloud manager URL. Read as the node URL when ``nodeURL`` is `nil`.
    public var cloudBaseURL: URL?
    /// Unused on 1.0 (packages install from the cluster's registry); kept so apps that set it build.
    public var registryURL: String?
    /// The name a new account is registered under (`signUp`).
    public var accountName: String?

    public init(
        nodeURL: String? = nil, nodes: [String] = [], policy: CloudPolicy = .production, packageName: String? = nil,
        packageVersion: String? = nil, cloudBaseURL: URL? = nil, registryURL: String? = nil, accountName: String? = nil
    ) {
        self.nodeURL = nodeURL
        self.nodes = nodes
        self.policy = policy
        self.packageName = packageName
        self.packageVersion = packageVersion
        self.cloudBaseURL = cloudBaseURL
        self.registryURL = registryURL
        self.accountName = accountName
    }

    /// The node to use: ``nodeURL``, else ``cloudBaseURL``.
    public var resolvedNodeURL: String? { nodeURL ?? cloudBaseURL?.absoluteString }
}

/// The SwiftUI side of a ``CalimeroClient``: who is signed in, to which
/// cluster, and the sign-in, restore and sign-out flows, published for views.
/// (== mero-react `useMero()`.) Keep one for the app's life; ``MeroAppSession``
/// holds one.
///
/// - Cloud sign-in: ``signIn(passkey:)`` with the device's passkey
///   (``PlatformPasskey``), or ``signUp(name:passkey:)`` for a new account.
/// - Development (`merod local`): ``connect(nodeURL:nodes:allowMock:)`` with
///   `allowMock: true`, then sign in; a ``SoftPasskey`` is made and kept per
///   node (``CloudSessionStore``), since a platform passkey cannot belong to
///   `localhost`.
/// - Sessions persist in the ``CloudSessionStore`` (the Keychain), refreshed
///   tokens included, so ``restore()`` reconnects without a passkey prompt.
@MainActor
public final class MeroClient: ObservableObject {
    public let config: MeroProviderConfig
    public let store: any CloudSessionStore
    let urlSession: URLSession
    let platformPasskey: (any PasskeyProvider)?

    /// The client in use, once connected to a node.
    @Published public private(set) var cloud: CalimeroClient?
    /// The signed-in session, or `nil`.
    @Published public private(set) var session: CalimeroSession?
    /// The node connected to.
    @Published public private(set) var nodeURL: String?
    /// Whether the connected node is trusted with mock attestation (a development cluster).
    @Published public private(set) var allowMock = false
    /// A call is running.
    @Published public private(set) var isLoading = false
    /// The last failure, in words for a person.
    @Published public var errorMessage: String?
    /// Bumped whenever who is signed in changes.
    @Published public private(set) var sessionRevision = 0

    private var nodes: [String] = []

    /// - Parameters:
    ///   - passkey: the passkey for real clusters; ``PlatformPasskey`` by default where there is one.
    public init(
        config: MeroProviderConfig = MeroProviderConfig(), store: any CloudSessionStore = MemoryCloudSessionStore(),
        session: URLSession = .shared, passkey: (any PasskeyProvider)? = nil
    ) {
        self.config = config
        self.store = store
        self.urlSession = session
        #if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
        self.platformPasskey = passkey ?? PlatformPasskey()
        #else
        self.platformPasskey = passkey
        #endif
        if let url = config.resolvedNodeURL {
            connect(nodeURL: url, nodes: config.nodes, allowMock: config.policy.allowMock)
        }
    }

    /// Signed in.
    public var isAuthenticated: Bool { session != nil }
    /// The signed-in account, or `nil`.
    public var account: String? { session?.accountId }

    /// Talk to `nodeURL` (and `nodes`, the rest of its cluster) from now on.
    /// `allowMock` trusts a development cluster's mock attestation; anything
    /// else is verified as ``MeroProviderConfig/policy`` says. Signs out of a
    /// different node.
    public func connect(nodeURL: String, nodes: [String] = [], allowMock: Bool = false) {
        let trimmed = nodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != self.nodeURL || allowMock != self.allowMock || cloud == nil else { return }
        var policy = config.policy
        policy.allowMock = allowMock
        let client = CalimeroClient(
            CalimeroClientOptions(baseUrl: trimmed, nodes: nodes, policy: policy, session: urlSession))
        self.nodeURL = trimmed
        self.nodes = nodes
        self.allowMock = allowMock
        cloud = client
        if session != nil {
            session = nil
            sessionRevision += 1
        }
        observe(client)
    }

    private func observe(_ client: CalimeroClient) {
        let store = self.store
        let url = nodeURL ?? ""
        let nodes = self.nodes
        let allowMock = self.allowMock
        let box = WeakMeroClient(self)
        Task {
            await client.onSessionChange { session in
                if let session {
                    store.save(StoredCloudSession(nodeURL: url, nodes: nodes, allowMock: allowMock, session: session))
                }
                Task { @MainActor in
                    guard let owner = box.value, owner.cloud === client else { return }
                    if owner.session?.accountId != session?.accountId { owner.sessionRevision += 1 }
                    owner.session = session
                }
            }
        }
    }

    /// The passkey to use on the connected node: the device's, or on a
    /// mock-attested development cluster a ``SoftPasskey`` kept for that node.
    public func passkeyForNode() -> (any PasskeyProvider)? {
        guard allowMock, let url = nodeURL else { return platformPasskey }
        if let json = store.softPasskey(for: url), let soft = try? SoftPasskey(json: json) { return soft }
        let soft = SoftPasskey()
        store.saveSoftPasskey(soft.json, for: url)
        return soft
    }

    /// Sign in with a passkey (`passkey`, else ``passkeyForNode()``). Returns
    /// whether it worked; a failure lands in ``errorMessage``.
    @discardableResult
    public func signIn(passkey: (any PasskeyProvider)? = nil) async -> Bool {
        await run { cloud in
            guard let key = passkey ?? self.passkeyForNode() else { throw AccountError.notSignedIn("no passkey") }
            try await cloud.signIn(key)
        }
    }

    /// Create an account with a new passkey and sign in.
    @discardableResult
    public func signUp(name: String, passkey: (any PasskeyProvider)? = nil) async -> Bool {
        await run { cloud in
            guard let key = passkey ?? self.passkeyForNode() else { throw AccountError.notSignedIn("no passkey") }
            try await cloud.signUp(key, name: name)
        }
    }

    /// Sign in, or, on a development cluster whose soft passkey has no account
    /// yet, sign up as ``MeroProviderConfig/accountName`` (or `name`).
    @discardableResult
    public func signInOrSignUp(name: String? = nil) async -> Bool {
        if await signIn() { return true }
        guard allowMock else { return false }
        errorMessage = nil
        return await signUp(name: name ?? config.accountName ?? "dev")
    }

    /// Reconnect the stored session, if there is one, refreshing it (which
    /// also proves the node still takes it). Returns whether it worked.
    @discardableResult
    public func restore() async -> Bool {
        guard let stored = store.load() else { return false }
        connect(nodeURL: stored.nodeURL, nodes: stored.nodes, allowMock: stored.allowMock)
        guard let cloud else { return false }
        await cloud.useSession(stored.session)
        session = stored.session
        sessionRevision += 1
        do {
            try await cloud.refresh()
            return true
        } catch is LoginRequired {
            store.clear()
            await cloud.forget()
            return false
        } catch {
            // Offline or the node is briefly away: keep the session; the next call refreshes.
            return true
        }
    }

    /// Sign out: end the session on the node (best effort) and forget it here.
    public func logout() async {
        if let cloud {
            do {
                try await cloud.signOut()
            } catch {
                await cloud.forget()
            }
        }
        store.clear()
        if session != nil { sessionRevision += 1 }
        session = nil
    }

    /// Ask the node for a consent page, open it in the system browser with
    /// `opener`, and answer the decision once the page sends the person back
    /// (or the sheet is dismissed). `nil` on a failure, in ``errorMessage``.
    public func requestConsent(
        _ request: (_ returnTo: String) -> ConsentRequest, callback: CloudCallback,
        opener: any WebAuthenticating = MeroClient.defaultOpener()
    ) async -> ConsentResult? {
        guard let cloud else {
            errorMessage = "Not connected to a node."
            return nil
        }
        do {
            let started = try await cloud.requestConsent(request(callback.url))
            guard let url = URL(string: started.url) else { throw AccountError.protocolViolation("bad consent URL") }
            _ = try? await opener.authenticate(url: url, callback: callback)
            return try await cloud.consentResult(started.requestId)
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    /// The system browser where there is one.
    public static func defaultOpener() -> any WebAuthenticating {
        #if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
        return SystemWebAuthenticator()
        #else
        return NoWebAuthenticator()
        #endif
    }

    private func run(_ work: @escaping (CalimeroClient) async throws -> Void) async -> Bool {
        guard let cloud else {
            errorMessage = "Enter a node URL first."
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await work(cloud)
            let current = await cloud.session
            if current?.accountId != session?.accountId { sessionRevision += 1 }
            session = current
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// `error` in words for a person.
    public nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case is PasskeyCancelled, is ConfirmCancelled: return "The passkey prompt was cancelled."
        case is WrongNode: return "This node may not serve your account. Try another node of the cluster."
        case is LoginRequired: return "Your session ended. Sign in again."
        case let error as UnavailableError: return "The cluster is unavailable (\(error.reason)). Try again shortly."
        case let error as AppError: return error.appCode.isEmpty ? error.message : error.appCode
        case let error as CalimeroError: return error.message.isEmpty ? error.code : error.message
        case let error as TeeTrustError: return "The node could not be verified: \(error.message)"
        default: return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// A ``WebAuthenticating`` for platforms without a system browser sheet: it opens nothing.
public struct NoWebAuthenticator: WebAuthenticating {
    public init() {}

    public func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        throw WebAuthenticationCancelled()
    }
}

/// A weak reference that may cross actors (read only on the main actor).
private final class WeakMeroClient: @unchecked Sendable {
    weak var value: MeroClient?

    init(_ value: MeroClient) {
        self.value = value
    }
}
