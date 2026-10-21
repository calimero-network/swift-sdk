import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One attempt at a relay's node key, and what became of it.
/// (== mero-js `RelayNodeKeyAttempt`.)
public enum RelayNodeKeyAttempt: Sendable {
    /// Verified (or already pinned), and pinned now.
    case learned(nodeKey: String)
    /// Something on the way did not answer — the relay, or what it named.
    /// Nothing was decided; try again.
    case unavailable(any Error)
    /// The relay answered and its proof did not hold: a quote not bound to
    /// this request, a mock from a hosted relay. Asking again cannot turn that
    /// into a yes, and must not.
    case refused(any Error)

    /// The key, when one was learned.
    public var nodeKey: String? {
        if case .learned(let key) = self { return key }
        return nil
    }
}

/// One item a relay listed for the account, and the relay that listed it.
/// (== mero-js `ListedContext & { relayUrl }`.)
public struct DelegatedListing<Item: Sendable>: Sendable {
    public let item: Item
    /// The relay that listed it, and is now recorded as serving it.
    public let relayUrl: String
}

extension DelegatedAccounts {
    // MARK: - Relay node key

    /// How long to wait before each retry of an unavailable relay key: quickly
    /// at first, then every 30 s for as long as it takes.
    /// (== mero-js `RELAY_NODE_KEY_RETRY_MS`, in seconds.)
    public static let relayNodeKeyRetrySchedule: [TimeInterval] = [1, 2, 5, 10, 30]

    /// The relay's node key: the pinned one, or else learned from the relay's
    /// TEE attestation (``RelayNodeKey/attest(relayURL:verifier:session:timeout:)``
    /// under ``DelegatedEnvironment/relayKeyVerifier``) and pinned for next
    /// time. (== mero-js `attemptRelayNodeKey`.)
    ///
    /// `fresh` skips the pin and attests now, for a step that hands the relay
    /// something it keeps — founding a namespace through it.
    public static func attemptRelayNodeKey(
        _ relayURL: String, fresh: Bool = false, env: DelegatedEnvironment = DelegatedEnvironment()
    ) async -> RelayNodeKeyAttempt {
        if !fresh, let pinned = env.store.pinnedRelayNodeKey(relayURL: relayURL) {
            return .learned(nodeKey: pinned)
        }
        do {
            let key = try await RelayNodeKey.attest(
                relayURL: relayOrigin(relayURL), verifier: env.relayKeyVerifier, session: env.urlSession,
                timeout: env.timeout)
            env.store.pinRelayNodeKey(relayURL: relayURL, nodeKey: key)
            return .learned(nodeKey: key.lowercased())
        } catch {
            return isTransportFailure(error) ? .unavailable(error) : .refused(error)
        }
    }

    /// The relay's node key in one attempt, `nil` when that attempt did not
    /// learn it. Callers that must end up with the key use
    /// ``learnRelayNodeKey(_:env:)``. (== mero-js `resolveRelayNodeKey`.)
    public static func resolveRelayNodeKey(
        _ relayURL: String, env: DelegatedEnvironment = DelegatedEnvironment()
    ) async -> String? {
        await attemptRelayNodeKey(relayURL, env: env).nodeKey
    }

    /// The relay's node key, however long the way to it is down: a transport
    /// failure is waited out on ``relayNodeKeyRetrySchedule`` until the key is
    /// learned or the calling task is cancelled (then `nil`). A refusal ends it
    /// at once with `nil`. (== mero-js `learnRelayNodeKey`.)
    public static func learnRelayNodeKey(
        _ relayURL: String, env: DelegatedEnvironment = DelegatedEnvironment()
    ) async -> String? {
        var failures = 0
        while !Task.isCancelled {
            switch await attemptRelayNodeKey(relayURL, env: env) {
            case .learned(let nodeKey):
                return nodeKey
            case .refused:
                return nil
            case .unavailable:
                let schedule = relayNodeKeyRetrySchedule
                let wait = schedule[min(failures, schedule.count - 1)]
                failures += 1
                await env.sleep(wait)
            }
        }
        return nil
    }

    /// Whether learning a key failed on the way rather than on the answer:
    /// no response, a non-2xx one, or a cancelled wait.
    static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case is URLError, is CancellationError, is RelayKeyTransportError:
            return true
        case let error as MeroError:
            switch error {
            case .network, .http, .authRevoked:
                return true
            case .decoding, .emptyResponse, .rpc, .authenticationFailed, .noCredentials, .noRefreshToken:
                return false
            }
        default:
            return false
        }
    }

    // MARK: - The delegated client

    /// The client a delegated session talks through: a relay-transport
    /// ``MeroTransportClient`` whose `rpc.execute` takes the node's named
    /// arguments, so a generated ABI client works unchanged. `nil` when the
    /// session has no relay — deliberately no placeholder, which would look
    /// connected and refuse every warrant. (== mero-js `buildDelegatedClient`.)
    ///
    /// - Writes are warrants, one nonce sequence per relay
    ///   (``DelegatedEnvironment/nonces``), whatever context is chosen.
    /// - `admin` and `events` are authenticated as the account by the device
    ///   certificate (request proofs), so the caller-scoped reads answer this
    ///   account's own contexts and namespaces.
    /// - With the relay's node key pinned, admin also holds an `account_proof`
    ///   session (a hosted relay's forward-auth takes a Bearer token, not a
    ///   proof), reads try `admin.queryContext` first — a `409` marks the
    ///   method a write, remembered per relay, context and method — and events
    ///   come through a ``RelayObserver``.
    /// - On a hosted relay whose key is not known yet, events are an inert
    ///   placeholder: its forward-auth would answer a proof-only stream `401`
    ///   forever. A loopback relay (a dev rig) takes the proof as a node does.
    ///
    /// `contextId` is kept for callers; the client does not depend on it.
    public static func buildDelegatedClient(
        _ session: DelegatedSession, contextId: String? = nil, env: DelegatedEnvironment = DelegatedEnvironment()
    ) throws -> MeroTransportClient? {
        _ = contextId
        guard let relayUrl = session.relayUrl else { return nil }
        let nodeKey = env.store.pinnedRelayNodeKey(relayURL: relayUrl)
        // Every request sealed to the relay's attested TD: intents, admin
        // reads, queries, the login and events.
        let transport = relayTransportSession(relayUrl, env: env)
        let relay = RelayClient(
            relayURL: relayUrl, authorAccount: session.account, authorProof: session.credential, keys: session.keys,
            nonces: env.nonces, ttlSeconds: env.warrantTTLSeconds, session: transport, timeout: env.timeout)
        var sessionToken: (@Sendable () async -> String?)?
        if let nodeKey {
            let minted = DelegatedRelaySession(
                session: session, relayURL: relayUrl, nodeKey: nodeKey, env: env, transport: transport)
            sessionToken = { await minted.token() }
        }
        let config = RelayTransportConfig(
            relay: relay, sessionToken: sessionToken,
            observe: RelayObserveConfig(nodeKey: nodeKey, audience: env.audience, clientName: env.clientName),
            proof: ProofCredential(credential: session.credential, keys: session.keys), urlSession: transport,
            timeout: env.timeout)
        let attested = nodeKey != nil || RelayNodeKey.isLoopback(relayUrl)
        return try MeroTransportClient(.relay(config), readsThroughQuery: nodeKey != nil, inertEvents: !attested)
    }

    // MARK: - Listing across relays

    /// This account's contexts on every relay it knows, each tagged with the
    /// relay that listed it — and that relay recorded as the one serving it.
    /// Each relay answers only for itself and this caller, so the union is
    /// exactly the account's contexts; a relay that cannot be reached or
    /// logged in to is skipped. When **every** relay failed it throws
    /// ``RelaysUnavailableError`` rather than answering an empty account.
    /// (== mero-js `listDelegatedContexts`.)
    public static func listDelegatedContexts(
        _ session: DelegatedSession, env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> [DelegatedListing<ContextWithGroup>] {
        var out: [DelegatedListing<ContextWithGroup>] = []
        var map = env.store.relayMap(account: session.account)
        let relays = knownRelays(session, store: env.store)
        var failures: [RelayListingFailure] = []
        for relayUrl in relays {
            let contexts: [ContextWithGroup]
            switch await listing(session, relayUrl: relayUrl, env: env, { try await $0.getContexts().contexts }) {
            case .success(let listed): contexts = listed
            case .failure(let failure):
                failures.append(failure)
                continue
            }
            for context in contexts {
                out.append(DelegatedListing(item: context, relayUrl: relayUrl))
                map.contexts[context.id] = relayUrl
            }
        }
        if !relays.isEmpty, failures.count == relays.count { throw RelaysUnavailableError(failures: failures) }
        env.store.setRelayMap(map, account: session.account)
        return out
    }

    /// This account's namespaces on every relay it knows, once each, tagged
    /// with the relay that listed it first and recorded as its relay unless
    /// one was already known. (== mero-js `listDelegatedNamespaces`.)
    public static func listDelegatedNamespaces(
        _ session: DelegatedSession, env: DelegatedEnvironment = DelegatedEnvironment()
    ) async throws -> [DelegatedListing<Namespace>] {
        var out: [DelegatedListing<Namespace>] = []
        var seen = Set<String>()
        var map = env.store.relayMap(account: session.account)
        let relays = knownRelays(session, store: env.store)
        var failures: [RelayListingFailure] = []
        for relayUrl in relays {
            let namespaces: [Namespace]
            switch await listing(session, relayUrl: relayUrl, env: env, { try await $0.listNamespaces() }) {
            case .success(let listed): namespaces = listed
            case .failure(let failure):
                failures.append(failure)
                continue
            }
            for namespace in namespaces where seen.insert(namespace.namespaceId).inserted {
                out.append(DelegatedListing(item: namespace, relayUrl: relayUrl))
                if map.namespaces[namespace.namespaceId] == nil { map.namespaces[namespace.namespaceId] = relayUrl }
            }
        }
        if !relays.isEmpty, failures.count == relays.count { throw RelaysUnavailableError(failures: failures) }
        env.store.setRelayMap(map, account: session.account)
        return out
    }

    /// One relay's answer to `read` on the account's admin there, or why it
    /// gave none: its key refused or unavailable, or the read itself failed.
    private static func listing<Item: Sendable>(
        _ session: DelegatedSession, relayUrl: String, env: DelegatedEnvironment,
        _ read: (AdminApi) async throws -> [Item]
    ) async -> Result<[Item], RelayListingFailure> {
        switch await attemptRelayNodeKey(relayUrl, env: env) {
        case .learned: break
        case .refused(let error): return .failure(RelayListingFailure(relayUrl: relayUrl, kind: .refused, error: error))
        case .unavailable(let error):
            return .failure(RelayListingFailure(relayUrl: relayUrl, kind: .unavailable, error: error))
        }
        do {
            guard let client = try buildDelegatedClient(session.on(relay: relayUrl), env: env) else {
                throw AccountError.notSignedIn("no relay")
            }
            return .success(try await read(try await client.admin))
        } catch {
            return .failure(RelayListingFailure(relayUrl: relayUrl, kind: .unavailable, error: error))
        }
    }
}

/// One relay a delegated listing could not read. (== mero-js `RelayListingFailure`.)
public struct RelayListingFailure: Error, Sendable {
    public enum Kind: String, Sendable {
        /// The relay's attestation did not hold: asking again will not help.
        case refused
        /// The relay, its login or its listing did not answer.
        case unavailable
    }

    public let relayUrl: String
    public let kind: Kind
    public let error: any Error
}

/// Every relay the account knows failed to list. Thrown by
/// ``DelegatedAccounts/listDelegatedContexts(_:env:)`` and
/// ``DelegatedAccounts/listDelegatedNamespaces(_:env:)`` instead of an empty
/// list, which an app would read as an account with nothing in it — and offer
/// to create what already exists. (== mero-js `RelaysUnavailableError`.)
public struct RelaysUnavailableError: Error, LocalizedError, Sendable {
    public let failures: [RelayListingFailure]

    /// True when every relay refused its attestation, so retrying will not help.
    public var refused: Bool { !failures.isEmpty && failures.allSatisfy { $0.kind == .refused } }

    public var errorDescription: String? {
        "none of this account's relays answered: "
            + failures.map { failure in
                let reason = (failure.error as? LocalizedError)?.errorDescription ?? "\(failure.error)"
                return "\(failure.relayUrl) (\(failure.kind.rawValue): \(reason))"
            }
            .joined(separator: "; ")
    }
}

/// A lazily minted `account_proof` session on a relay, for its admin API.
/// (== mero-js `relaySession`.)
///
/// A hosted relay's `/admin-api/` sits behind forward-auth that answers a
/// Bearer token or `401`. Minted on first use and again once it is within
/// 30 s of expiring (a token whose lifetime cannot be read is kept). On a
/// failed login it yields `nil`: the request goes out with the proof alone
/// and the node's `401` is what the caller sees; the next call tries again.
actor DelegatedRelaySession {
    private let session: DelegatedSession
    private let relayURL: String
    private let nodeKey: String
    private let env: DelegatedEnvironment
    /// Sealed to the relay's TD: the token is the session, and TLS ends outside it.
    private let transport: URLSession
    private var accessToken: String?
    private var pending: Task<String?, Never>?

    init(
        session: DelegatedSession, relayURL: String, nodeKey: String, env: DelegatedEnvironment, transport: URLSession
    ) {
        self.session = session
        self.relayURL = relayURL
        self.nodeKey = nodeKey
        self.env = env
        self.transport = transport
    }

    func token() async -> String? {
        if let accessToken {
            let exp = expiresAtFromJWT(accessToken, fallback: .distantFuture)
            if exp.timeIntervalSinceNow > 30 { return accessToken }
        }
        if let pending { return await pending.value }
        let session = self.session
        let relayURL = self.relayURL
        let nodeKey = self.nodeKey
        let env = self.env
        let transport = self.transport
        let task = Task<String?, Never> {
            try? await RelayLogin.login(
                relayURL: relayURL, nodeKey: nodeKey, credential: session.credential, keys: session.keys,
                audience: env.audience, clientName: env.clientName, session: transport, timeout: env.timeout
            ).accessToken
        }
        pending = task
        defer { pending = nil }
        let minted = await task.value
        accessToken = minted
        return minted
    }
}
