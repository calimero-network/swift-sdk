import Foundation

// A context's contract, as an app on a phone reaches it. There is no node on
// the phone, so there is no JSON-RPC: a read is the relay's account-scoped
// query, a write is a warrant the device key signs. Every app makes the same
// two calls; only the method names differ, and those belong to the app (or to
// the client mero-devtools-js generates for it, over ``ContextContractCalling``).

/// The two ways an app reaches the contract in a context.
/// (== Kotlin `com.calimero.mero.app.ContextContract`.)
///
/// ``RelayContextContract`` is the real one; ``NoRelayContextContract`` stands
/// in for an account no relay serves yet. ``bound(to:)`` fixes the context, for
/// a generated client.
public protocol ContextContract: Sendable {
    /// Run a view (`#[app::view]`) as the account, through the relay's query path.
    func query(contextId: String, method: String, args: JSONValue) async throws -> JSONValue?
    /// Run a mutation as the account: a warrant posted to the relay's intents route.
    func execute(contextId: String, method: String, args: JSONValue) async throws -> JSONValue?
}

extension ContextContract {
    /// This contract with `contextId` fixed: what a generated client calls.
    public func bound(to contextId: String) -> BoundContextContract {
        BoundContextContract(contract: self, contextId: contextId)
    }
}

/// ``ContextContract`` over the account's ``RelayClient``.
/// (== Kotlin `RelayContextContract`.)
///
/// - `query` is `POST /admin-api/contexts/{id}/query` with the relay session's
///   Bearer token (``RelayClient/query(contextId:method:argsJson:)``). Without a
///   session, or when the relay says the method is a write, it falls back to a
///   warrant, which reads too.
/// - `execute` is `POST /admin-api/contexts/{id}/intents` carrying a warrant the
///   device key signs (``RelayClient/execute(contextId:method:argsJson:)``); the
///   method's return value is its `returns`.
public struct RelayContextContract: ContextContract {
    public let relay: RelayClient

    public init(relay: RelayClient) {
        self.relay = relay
    }

    public func query(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        try await relay.query(contextId: contextId, method: method, argsJson: args)
    }

    public func execute(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        try await relay.execute(contextId: contextId, method: method, argsJson: args).returns
    }
}

/// The contract of an account no relay serves yet: every call throws
/// ``AccountError/noRelay(method:)``, naming the method. Redeeming an
/// invitation is how the account gets a relay. (== Kotlin `NoRelayContextContract`.)
public struct NoRelayContextContract: ContextContract {
    public init() {}

    public func query(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        throw AccountError.noRelay(method: method)
    }

    public func execute(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        throw AccountError.noRelay(method: method)
    }
}

/// One context's contract, in the shape a generated client calls: JSON in,
/// JSON out, as UTF-8 bytes. (== Kotlin `ContextContractCalling`, which takes
/// and returns strings.)
///
/// ``BoundContextContract`` is the SDK's; ``ContextContract/bound(to:)`` makes one.
public protocol ContextContractCalling: Sendable {
    /// Run a view: `argsJSON` is the argument object; the result is the
    /// method's return value as JSON (`null` when it returns nothing).
    func query(method: String, argsJSON: Data) async throws -> Data
    /// Run a mutation: as ``query(method:argsJSON:)``, through a warrant.
    func execute(method: String, argsJSON: Data) async throws -> Data
}

/// A ``ContextContract`` with its context fixed. (== Kotlin `BoundContextContract`.)
///
/// Empty `argsJSON` is read as `{}`, and anything that is not JSON is refused
/// (``AccountError/invalidInput(_:)``) before a request is made. Numbers travel
/// as ``JSONValue/number(_:)``, a `Double`, as every other call through the
/// relay does: an integer beyond 2^53 does not survive the trip; send it as a
/// string.
public struct BoundContextContract: ContextContractCalling {
    public let contract: any ContextContract
    public let contextId: String

    public init(contract: any ContextContract, contextId: String) {
        self.contract = contract
        self.contextId = contextId
    }

    public func query(method: String, argsJSON: Data) async throws -> Data {
        let result = try await contract.query(contextId: contextId, method: method, args: try Self.args(argsJSON))
        return CanonicalJSON.data(result ?? .null)
    }

    public func execute(method: String, argsJSON: Data) async throws -> Data {
        let result = try await contract.execute(contextId: contextId, method: method, args: try Self.args(argsJSON))
        return CanonicalJSON.data(result ?? .null)
    }

    static func args(_ data: Data) throws -> JSONValue {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AccountError.invalidInput("argsJSON is not JSON: \(error.localizedDescription)")
        }
    }
}
