import Foundation

// One call shape, two ways of getting there. Port of mero-js
// `src/transport/types.ts` and `relay-transport.ts`.
//
// ``RpcClient/execute(contextId:method:argsJson:)`` is what every app already
// writes; ``RelayClient/execute(contextId:method:argsJson:)`` grew separately,
// with a JSON body and an ``IntentResult``. ``ExecuteTransport`` declares the
// node's shape the contract and adapts the relay to it, so switching a
// connection from a node to a relay changes no call site.
//
// Subscription is not on this protocol: ``RpcClient`` satisfies it as it
// ships, and has never subscribed. Observation lives on
// ``MeroTransportClient`` (`events`, `ws`), and ``canSubscribe`` says whether
// it will work, so an app branches on data rather than on a thrown error.

/// What ``ExecuteTransport/executeWithMetadata(contextId:method:argsJson:)``
/// returns. (== mero-js `ExecuteResult`.)
public typealias ExecuteResult<T: Sendable> = RpcExecuteResult<T>

/// The write surface an app codes against, whichever transport is underneath.
/// (== mero-js `ExecuteTransport`.)
///
/// ``RpcClient`` conforms as it is, so an app already holding one already
/// holds an `ExecuteTransport`.
public protocol ExecuteTransport: Sendable {
    /// Which path this is: for diagnostics and feature-gating UI.
    var kind: RpcTransportKind { get }

    /// Whether this transport can observe events **as configured**.
    ///
    /// Always `true` on a node. On a relay it depends on whether the relay's
    /// node key was supplied: the relay serves `/sse` and `/ws` like any node,
    /// but the login statement is signed against a key learned out of band.
    var canSubscribe: Bool { get }

    /// Run one method in one context. The canonical signature.
    func execute<T: Decodable>(contextId: String, method: String, argsJson: [String: JSONValue]) async throws -> T

    /// The same call, with whatever the transport knows about the write.
    func executeWithMetadata<T: Decodable & Sendable>(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> ExecuteResult<T>

    /// One-tap owner-driven convert (`migrate_my_entries`).
    func migrateMyEntries(_ contextId: String) async throws -> MigrateMyEntriesSummary

    /// Read-only count of the caller's entries still below the target schema.
    func countMyPending(_ contextId: String) async throws -> Int
}

extension RpcClient: ExecuteTransport {
    /// Always ``RpcTransportKind/node``.
    public var kind: RpcTransportKind { .node }
    /// Always `true`: a node client holds a credential on the node it calls.
    public var canSubscribe: Bool { true }
}

/// A ``Mero``'s JSON-RPC client as an ``ExecuteTransport``, reachable without
/// awaiting the actor. Each call is ``Mero/rpc``'s, unchanged.
public struct MeroRpcTransport: ExecuteTransport {
    public let mero: Mero

    public init(mero: Mero) { self.mero = mero }

    public var kind: RpcTransportKind { .node }
    public var canSubscribe: Bool { true }

    public func execute<T: Decodable>(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> T {
        try await mero.rpc.execute(contextId: contextId, method: method, argsJson: argsJson)
    }

    public func executeWithMetadata<T: Decodable & Sendable>(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> ExecuteResult<T> {
        try await mero.rpc.executeWithMetadata(contextId: contextId, method: method, argsJson: argsJson)
    }

    public func migrateMyEntries(_ contextId: String) async throws -> MigrateMyEntriesSummary {
        try await mero.rpc.migrateMyEntries(contextId)
    }

    public func countMyPending(_ contextId: String) async throws -> Int {
        try await mero.rpc.countMyPending(contextId)
    }
}

/// The relay, wearing the node's `execute` shape. (== mero-js `RelayTransport`.)
///
/// An adapter and nothing else: it owns no protocol, mints no warrant and
/// holds no key — ``RelayClient`` does all of that. What lives here is the
/// two differences that kept an app from swapping one for the other: named
/// arguments instead of a JSON body, and `T` instead of ``IntentResult``. The
/// `rootHash` the relay also reports is not discarded: it comes back from
/// ``executeWithMetadata(contextId:method:argsJson:)``.
public struct RelayTransport: ExecuteTransport {
    /// The underlying client, for `describe` and anything else relay-specific.
    public let client: RelayClient
    /// How this transport observes, or `nil` when nobody supplied the relay
    /// node's signing key.
    public let observer: RelayObserver?

    public init(client: RelayClient, observer: RelayObserver? = nil) {
        self.client = client
        self.observer = observer
    }

    public var kind: RpcTransportKind { .relay }

    /// Whether this relay can be observed: a fact about the configuration
    /// (a node key was supplied), not a constant of the transport.
    public var canSubscribe: Bool { observer != nil }

    public func execute<T: Decodable>(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> T {
        let result = try await client.execute(contextId: contextId, method: method, argsJson: .object(argsJson))
        return try decodeReturns(T.self, result.returns)
    }

    public func executeWithMetadata<T: Decodable & Sendable>(
        contextId: String, method: String, argsJson: [String: JSONValue]
    ) async throws -> ExecuteResult<T> {
        let result = try await client.execute(contextId: contextId, method: method, argsJson: .object(argsJson))
        return ExecuteResult(
            returns: try decodeReturns(T.self, result.returns), transport: .relay, rootHash: result.rootHash)
    }

    /// A plain context method: the warrant names `migrate_my_entries`, and the
    /// delta is attributed to the author the convert is scoped to.
    public func migrateMyEntries(_ contextId: String) async throws -> MigrateMyEntriesSummary {
        try await execute(contextId: contextId, method: "migrate_my_entries", argsJson: [:])
    }

    public func countMyPending(_ contextId: String) async throws -> Int {
        try await execute(contextId: contextId, method: "count_my_pending", argsJson: [:])
    }
}

/// A method's `returns` decoded into `T`. A missing value is JSON `null`, as a
/// node reports a null output, so `T` may be an `Optional`.
func decodeReturns<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
    do {
        return try MeroJSON.decode(T.self, from: try MeroJSON.encode(value ?? .null))
    } catch {
        throw MeroError.decoding("the method's return value is not a \(T.self): \(error)")
    }
}
