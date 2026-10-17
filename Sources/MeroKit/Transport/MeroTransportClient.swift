import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// One client, two transports — chosen once, at construction. Port of mero-js
// `src/transport/mero-client.ts` (`MeroClient` there; named apart here from
// MeroKitUI's observable `MeroClient`).
//
// After construction, `client.rpc.execute(contextId:method:argsJson:)` is the
// same call against a node and against a relay. Events work on both, given
// the relay's node key or the device certificate. What a relay does not have
// — a node's auth API, its bundled cloud client — throws naming what is
// missing, rather than quietly connecting to a node the app never chose.

/// The node transport: a ``Mero``, and the cloud client to hand out.
public struct NodeTransportConfig: Sendable {
    public var mero: Mero
    /// What ``MeroTransportClient/cloud`` returns; the hosted manager by default.
    public var cloud: CloudClient

    public init(mero: Mero, cloud: CloudClient = CloudClient()) {
        self.mero = mero
        self.cloud = cloud
    }

    /// A new ``Mero`` from `config`.
    public init(config: MeroConfig, session: URLSession = .shared, cloud: CloudClient = CloudClient()) {
        self.init(mero: Mero(config: config, session: session), cloud: cloud)
    }
}

/// The relay transport: delegated execution, no node and no node credential.
/// (== mero-js `RelayTransportConfig`.)
public struct RelayTransportConfig: Sendable {
    /// The relay to write through, already configured (``connectCloud(_:)``
    /// and ``CloudSignIn/connect(_:)`` hand one back).
    public var relay: RelayClient
    /// A session on the relay, if this client has one: the current access
    /// token, asked for per request so a re-minted session is picked up. It
    /// authenticates the admin reads; a session wins over ``proof`` where both
    /// are given, as the node itself would.
    public var sessionToken: (@Sendable () async -> String?)?
    /// How to observe the relay node; without a ``RelayObserveConfig/nodeKey``
    /// the client writes but does not observe through a session.
    public var observe: RelayObserveConfig?
    /// The device certificate this client signs its own requests with
    /// (`X-Calimero-Proof`): admin reads and events with no session and no
    /// node key.
    public var proof: ProofCredential?
    /// For the admin reads, events and the observing login.
    public var urlSession: URLSession
    public var timeout: TimeInterval

    public init(
        relay: RelayClient, sessionToken: (@Sendable () async -> String?)? = nil, observe: RelayObserveConfig? = nil,
        proof: ProofCredential? = nil, urlSession: URLSession = .shared, timeout: TimeInterval = 10
    ) {
        self.relay = relay
        self.sessionToken = sessionToken
        self.observe = observe
        self.proof = proof
        self.urlSession = urlSession
        self.timeout = timeout
    }
}

/// Which transport a ``MeroTransportClient`` is built on. (== mero-js `MeroClientConfig`.)
public enum MeroTransportConfig: Sendable {
    case node(NodeTransportConfig)
    case relay(RelayTransportConfig)
}

/// What ``MeroTransportClient/ephemeral`` is on each transport.
public enum EphemeralSurface: Sendable {
    /// A node's `set_ephemeral` presence.
    case node(EphemeralClient)
    /// An account's device-signed presence through the relay.
    case relay(RelayPresenceClient)
}

/// Why a ``MeroTransportClient`` surface is not there.
public enum MeroTransportError: Error, Sendable, Equatable {
    /// The relay transport has no such surface (`node`, `auth`, `cloud`).
    case relayHasNo(surface: String, why: String)
    /// The relay can be observed, but no node key (and no proof) was given.
    case missingNodeKey(surface: String)
    /// A relay client given neither a session nor a proof has no admin surface.
    case noAdminCredential
    /// `relay` on a node client.
    case nodeHasNoRelay
    /// A request proof cannot open a WebSocket here.
    case proofCannotOpenWebSocket
}

extension MeroTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .relayHasNo(let surface, let why):
            return "this client was constructed with the relay transport, which has no \(surface): \(why). "
                + "Construct a node client for that surface — nothing here will silently connect to a node you did "
                + "not choose."
        case .missingNodeKey(let surface):
            return "this relay-transport client cannot open \(surface): it was given no relay node key. A relay is "
                + "an ordinary node and does serve /sse and /ws — but the login statement must be signed against "
                + "the node's device signing key, learned out of band (never read from the node, and never derived "
                + "from its peerId). Pass it as `observe: RelayObserveConfig(nodeKey:)`, or pass `proof`."
        case .noAdminCredential:
            return "this relay-transport client has no admin surface because it was given neither a `proof` nor a "
                + "`sessionToken`. A warrant authorises one intent and is not a credential for reading. Pass "
                + "`proof: ProofCredential(credential:keys:)` — the device cert you already hold — or a session. "
                + "Context STATE reads work through execute/query either way."
        case .nodeHasNoRelay:
            return "this client was constructed with the node transport and has no relay"
        case .proofCannotOpenWebSocket:
            return "this client authenticates with a request proof, which cannot open the WebSocket: `WsClient` "
                + "authorizes its upgrade with a bearer token only and has no request-proof authorizer. Use "
                + "`events` (SSE), which carries the X-Calimero-Proof header."
        }
    }
}

/// A connection whose transport was decided at construction.
/// (== mero-js `MeroClient`.)
public final class MeroTransportClient: @unchecked Sendable {
    /// Which path writes take. Set once.
    public let transport: RpcTransportKind
    /// The write surface, identical on both transports.
    public let rpc: any ExecuteTransport

    private let nodeClient: Mero?
    private let nodeCloud: CloudClient?
    private let relayClient: RelayClient?
    private let relayObserver: RelayObserver?
    private let relayAdmin: AdminApi?
    private let proofAuthorizer: RequestAuthorizer?
    private let relayBase: URL?
    private let urlSession: URLSession
    /// Delegated sessions on a hosted relay not attested yet: events open nothing.
    private let inertEvents: Bool

    private let lock = NSLock()
    private var proofEvents: SseConnection?
    private var dormantEvents: SseConnection?
    private var relayPresence: RelayPresenceClient?

    /// Build a client for the chosen transport. Throws only for a ``RelayTransportConfig/proof``
    /// that cannot sign.
    public convenience init(_ config: MeroTransportConfig) throws {
        try self.init(config, readsThroughQuery: false, inertEvents: false)
    }

    /// A node client. (== `createMeroClient({ baseUrl })`.)
    public convenience init(mero: Mero, cloud: CloudClient = CloudClient()) {
        try! self.init(
            .node(NodeTransportConfig(mero: mero, cloud: cloud)), readsThroughQuery: false, inertEvents: false)
    }

    /// - Parameters:
    ///   - readsThroughQuery: route `rpc` reads through the session's
    ///     `admin.queryContext` first (a delegated session; needs a session).
    ///   - inertEvents: hand out an event stream that opens nothing, and
    ///     report `canSubscribe == false` (a hosted relay not attested yet).
    init(_ config: MeroTransportConfig, readsThroughQuery: Bool, inertEvents: Bool) throws {
        self.inertEvents = inertEvents
        switch config {
        case .node(let node):
            transport = .node
            nodeClient = node.mero
            nodeCloud = node.cloud
            relayClient = nil
            relayObserver = nil
            relayAdmin = nil
            proofAuthorizer = nil
            relayBase = nil
            urlSession = .shared
            rpc = MeroRpcTransport(mero: node.mero)
        case .relay(let relay):
            transport = .relay
            nodeClient = nil
            nodeCloud = nil
            urlSession = relay.urlSession
            relayClient = relay.relay
            relayBase = URL(string: relay.relay.relayURL)
            let observer = MeroTransportClient.makeObserver(relay)
            relayObserver = observer
            let authorizer = try relay.proof.map { try createProofAuthorizer($0) }
            proofAuthorizer = authorizer
            let admin = MeroTransportClient.makeAdmin(relay, authorizer: authorizer)
            relayAdmin = admin
            let inner = RelayTransport(client: relay.relay, observer: observer)
            if readsThroughQuery, relay.sessionToken != nil, let admin {
                rpc = QueryFirstTransport(inner: inner, admin: admin, relayURL: relay.relay.relayURL)
            } else {
                rpc = inner
            }
        }
    }

    /// The observer for a relay config, or `nil` when no node key was given.
    /// The single place that decision is made, so `canSubscribe`, `events`
    /// and `ws` cannot disagree about it.
    private static func makeObserver(_ config: RelayTransportConfig) -> RelayObserver? {
        guard let observe = config.observe, let nodeKey = observe.nodeKey, !nodeKey.isEmpty else { return nil }
        let relay = config.relay
        return RelayObserver(
            nodeURL: observe.nodeURL ?? relay.relayURL, nodeKey: nodeKey,
            accountProof: observe.accountProof ?? relay.authorProof, keys: observe.keys ?? relay.deviceKeys,
            audience: observe.audience ?? .current, clientName: observe.clientName,
            ttlSeconds: observe.ttlSeconds ?? RelayLogin.defaultTTLSeconds, timeout: observe.timeout ?? config.timeout,
            session: config.urlSession)
    }

    /// The relay's admin API as the account: by the session when there is
    /// one, else by the request proof, else none.
    private static func makeAdmin(_ config: RelayTransportConfig, authorizer: RequestAuthorizer?) -> AdminApi? {
        guard let base = URL(string: config.relay.relayURL) else { return nil }
        let hooks: TransportHooks
        if let token = config.sessionToken {
            hooks = TransportHooks(getAuthToken: token)
        } else if let authorizer {
            hooks = TransportHooks(authorizeRequest: authorizer)
        } else {
            return nil
        }
        let http = URLSessionHttpClient(
            baseURL: base, timeout: config.timeout, hooks: hooks, session: config.urlSession)
        return AdminApi(http: http)
    }

    // MARK: - Surfaces

    /// Whether ``events`` / ``ws`` will work: always on a node; on a relay,
    /// whether a node key or a proof was supplied.
    public var canSubscribe: Bool {
        if inertEvents { return false }
        return rpc.canSubscribe || proofAuthorizer != nil
    }

    /// The underlying ``Mero``. Node transport only.
    public var node: Mero {
        get throws {
            guard let nodeClient else {
                throw MeroTransportError.relayHasNo(
                    surface: "node connection", why: "it holds a signing key and a relay URL, not a node")
            }
            return nodeClient
        }
    }

    /// The underlying ``RelayClient``. Relay transport only.
    public var relay: RelayClient {
        get throws {
            guard let relayClient else { throw MeroTransportError.nodeHasNoRelay }
            return relayClient
        }
    }

    /// The admin surface: the node's own, or the relay's **authenticated as
    /// the account** (a session or a proof), whose caller-scoped reads answer
    /// this account's own contexts and namespaces. Mutations are not filtered:
    /// the node refuses what a delegated session may not do, naming the
    /// missing permission.
    public var admin: AdminApi {
        get async throws {
            if let nodeClient { return await nodeClient.admin }
            if let relayAdmin { return relayAdmin }
            throw MeroTransportError.noAdminCredential
        }
    }

    /// Auth API. Node transport only — a relay issues no node credential.
    public var auth: AuthApi {
        get async throws {
            try await node.auth
        }
    }

    /// SSE events, on both transports: the node's ``Mero/sse``, the
    /// observer's session-backed stream, or one signed by the request proof.
    /// The same connection every time.
    public var events: SseConnection {
        get throws {
            if let nodeClient { return nodeClient.sse }
            if inertEvents { return locked { dormant() } }
            if let relayObserver { return relayObserver.events }
            if let proofAuthorizer, let relayBase {
                return locked {
                    if let proofEvents { return proofEvents }
                    let made = SseConnection(baseURL: relayBase, authorize: proofAuthorizer, session: urlSession)
                    proofEvents = made
                    return made
                }
            }
            throw MeroTransportError.missingNodeKey(surface: "SSE events")
        }
    }

    /// **Experimental** WebSocket events, on both transports. Prefer ``events``.
    public var ws: WsClient {
        get throws {
            if let nodeClient { return nodeClient.ws }
            if let relayObserver { return relayObserver.ws }
            if proofAuthorizer != nil { throw MeroTransportError.proofCannotOpenWebSocket }
            throw MeroTransportError.missingNodeKey(surface: "WebSocket events")
        }
    }

    /// Ephemeral presence: the node's ``EphemeralClient``, or on a relay the
    /// account's ``RelayPresenceClient`` — device-signed, resent every 2.5 s,
    /// publishing with no node key (only reading needs ``events``).
    public var ephemeral: EphemeralSurface {
        get async throws {
            if let nodeClient { return .node(await nodeClient.ephemeral) }
            let relay = try self.relay
            return .relay(
                locked {
                    if let relayPresence { return relayPresence }
                    let made = RelayPresenceClient(relay: relay, events: { [weak self] in try? self?.events })
                    relayPresence = made
                    return made
                })
        }
    }

    /// Calimero Cloud. Node transport only: a relay client is built from a
    /// cloud connection rather than owning one.
    public var cloud: CloudClient {
        get throws {
            guard let nodeCloud else {
                throw MeroTransportError.relayHasNo(
                    surface: "bundled cloud client",
                    why: "a relay client is built from a cloud connection rather than owning one: use the `cloud` "
                        + "of the CloudConnection it came from, or construct a CloudClient directly")
            }
            return nodeCloud
        }
    }

    /// Release whatever the transport holds. Safe on either transport.
    public func close() async {
        await nodeClient?.close()
        relayObserver?.close()
        let signed = locked { proofEvents }
        let inert = locked { dormantEvents }
        signed?.close()
        inert?.close()
    }

    // MARK: - Helpers

    /// An event stream that opens nothing: its connect waits until it is
    /// closed, holding its subscriptions, emitting no error and reaching the
    /// network never. The client built once the relay's key is known brings
    /// the session-backed stream. (== mero-js `dormantEvents`.)
    private func dormant() -> SseConnection {
        if let dormantEvents { return dormantEvents }
        let base = relayBase ?? URL(fileURLWithPath: "/")
        let made = SseConnection(
            baseURL: base,
            authorize: { _ in
                try await Task.sleep(nanoseconds: UInt64.max / 2)
                throw CancellationError()
            }, session: urlSession)
        dormantEvents = made
        return made
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// `rpc` with reads routed through `admin.queryContext`: the session-
/// authenticated query for a method the node knows as a view, the warrant for
/// everything else. (== mero-js `readsThroughQuery`.)
///
/// A call carries no marker of which it is, so the node's own answer tells
/// them apart: a method is tried as a query first, and a `409` says it is a
/// write — remembered per relay, context and method (``MethodKinds``) so the
/// probe is paid once. Any other failure of the query is not an answer about
/// the method, so the call falls back to the warrant, which reads too.
struct QueryFirstTransport: ExecuteTransport {
    let inner: RelayTransport
    let admin: AdminApi
    let relayURL: String

    var kind: RpcTransportKind { inner.kind }
    var canSubscribe: Bool { inner.canSubscribe }

    func execute<T: Decodable>(contextId: String, method: String, argsJson: [String: JSONValue]) async throws -> T {
        if let returns = try await queried(contextId: contextId, method: method, argsJson: argsJson) {
            return try decodeReturns(T.self, returns.value)
        }
        return try await inner.execute(contextId: contextId, method: method, argsJson: argsJson)
    }

    func executeWithMetadata<T: Decodable & Sendable>(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> ExecuteResult<T> {
        if let returns = try await queried(contextId: contextId, method: method, argsJson: argsJson) {
            // No root hash: a read changes nothing, and `nil` is "unknown here".
            return ExecuteResult(returns: try decodeReturns(T.self, returns.value), transport: .relay)
        }
        return try await inner.executeWithMetadata(contextId: contextId, method: method, argsJson: argsJson)
    }

    func migrateMyEntries(_ contextId: String) async throws -> MigrateMyEntriesSummary {
        try await inner.migrateMyEntries(contextId)
    }

    func countMyPending(_ contextId: String) async throws -> Int {
        try await inner.countMyPending(contextId)
    }

    /// One query attempt: the returns (boxed, a `nil` value being a `null`
    /// return) when the node answered it as a view, `nil` to use the warrant.
    private func queried(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> QueriedReturns? {
        let key = "\(relayURL)|\(contextId)|\(method)"
        guard MethodKinds.shared.get(key) != .write else { return nil }
        do {
            let answer = try await admin.queryContext(
                contextId, request: QueryContextRequest(method: method, argsJson: .object(argsJson)))
            MethodKinds.shared.set(key, .read)
            return QueriedReturns(value: answer.returns)
        } catch {
            if classifyError(error).status == 409 { MethodKinds.shared.set(key, .write) }
            return nil
        }
    }
}

/// A query's `returns`, which may itself be absent (a `null` return).
struct QueriedReturns: Sendable {
    let value: JSONValue?
}
