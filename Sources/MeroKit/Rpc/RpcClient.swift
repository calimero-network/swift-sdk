import Foundation

/// Result of the owner-driven `migrate_my_entries` convert (counts are u32).
public struct MigrateMyEntriesSummary: Codable, Sendable, Equatable {
    public let converted: Int
    public let remaining: Int
}

/// How an execute result was carried. (== mero-js `ExecuteTransport.kind`.)
public enum RpcTransportKind: String, Sendable, Equatable {
    /// Straight to a node's `/jsonrpc`.
    case node
    /// Through a relay, as a warranted intent (or a session query for a read).
    case relay
}

/// The result of ``RpcClient/executeWithMetadata(contextId:method:argsJson:)``,
/// and of any ``ExecuteTransport``. (== mero-js `ExecuteResult`.)
public struct RpcExecuteResult<T: Sendable>: Sendable {
    /// Exactly what `execute` would have returned.
    public let returns: T
    /// Which transport ran it.
    public let transport: RpcTransportKind
    /// The context's scope root after the run, hex — relay writes only.
    ///
    /// `nil` on the node transport because JSON-RPC `execute` does not report
    /// it, and on a relay read because nothing was written. `nil` therefore
    /// means "unknown here", never "nothing changed".
    public let rootHash: String?

    public init(returns: T, transport: RpcTransportKind, rootHash: String? = nil) {
        self.returns = returns
        self.transport = transport
        self.rootHash = rootHash
    }
}

extension RpcExecuteResult: Equatable where T: Equatable {}

/// JSON-RPC 2.0 client for contract `execute` calls. (== mero-js `rpc/index.ts`.)
///
/// Since core rc.83 an execute needs `context:execute` in the token (or
/// `admin`), and a session authenticated as an ACCOUNT cannot execute at all:
/// it writes through a warranted intent instead. A node holding only a
/// read-only replica answers ``RpcError/isReadOnlyWriteRefused``.
public struct RpcClient: Sendable {
    let http: any HttpClient

    public init(http: any HttpClient) {
        self.http = http
    }

    private struct Request: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method = "execute"
        let params: Params
        struct Params: Encodable {
            let contextId: String
            let method: String
            let argsJson: [String: JSONValue]
        }
    }

    private struct Response<Output: Decodable>: Decodable {
        struct Result: Decodable { let output: Output? }
        struct RPCErr: Decodable {
            let code: Int?
            let message: String?
            let type: String?
            let data: JSONValue?
        }
        let result: Result?
        let error: RPCErr?
    }

    /// Execute a contract method and decode `result.output` into `T`.
    /// Maps a JSON-RPC `error` object to ``RpcError`` (via ``MeroError/rpc(_:)``).
    public func execute<T: Decodable>(
        contextId: String,
        method: String,
        argsJson: [String: JSONValue] = [:]
    ) async throws -> T {
        // No `executorPublicKey`: core's `ExecutionRequest` is
        // `deny_unknown_fields` with only these three, so naming one was a refusal.
        let body = Request(params: .init(contextId: contextId, method: method, argsJson: argsJson))
        let bodyData = try MeroJSON.encode(body)
        let (data, _) = try await http.sendRaw(HttpRequest(path: "/jsonrpc", method: .post, body: .json(bodyData)))

        let decoded: Response<T>
        do {
            decoded = try MeroJSON.decode(Response<T>.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw MeroError.decoding("JSON-RPC response: \(snippet)")
        }

        if let err = decoded.error {
            throw MeroError.rpc(
                RpcError(
                    code: err.code ?? -1,
                    message: err.message ?? Self.describe(type: err.type, data: err.data) ?? "RPC error",
                    type: err.type,
                    data: err.data
                ))
        }

        if let output = decoded.result?.output { return output }
        // A method that returns nothing (`()` in Rust) answers `output: null`,
        // or no `output` at all. That is a success: a caller asking for an
        // optional or a `JSONValue` gets `nil` / `.null` back.
        if decoded.result != nil, let none = try? MeroJSON.decode(T.self, from: Data("null".utf8)) {
            return none
        }
        throw MeroError.emptyResponse("JSON-RPC result had no output")
    }

    private struct CallRequest<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: Params
    }

    private struct CallResponse: Decodable {
        let result: JSONValue?
        let error: Response<JSONValue>.RPCErr?
    }

    /// Call any JSON-RPC method on `/jsonrpc` and return its `result` (`nil`
    /// when the node sent none). A JSON-RPC `error` object throws
    /// ``MeroError/rpc(_:)``, keeping the node's `type` and `data`.
    /// (== mero-js `jsonRpcCall`.)
    @discardableResult
    public func call<Params: Encodable & Sendable>(_ method: String, params: Params) async throws -> JSONValue? {
        let bodyData = try MeroJSON.encode(CallRequest(method: method, params: params))
        let (data, _) = try await http.sendRaw(HttpRequest(path: "/jsonrpc", method: .post, body: .json(bodyData)))
        let decoded: CallResponse
        do {
            decoded = try MeroJSON.decode(CallResponse.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw MeroError.decoding("JSON-RPC response: \(snippet)")
        }
        if let err = decoded.error {
            throw MeroError.rpc(
                RpcError(
                    code: err.code ?? -1,
                    message: err.message ?? Self.describe(type: err.type, data: err.data) ?? "RPC error",
                    type: err.type,
                    data: err.data
                ))
        }
        return decoded.result
    }

    /// Execute, returning the output together with how it was carried.
    ///
    /// The shape mero-js's transport abstraction shares between a direct node
    /// call and a relay; here the transport is always `"node"`.
    public func executeWithMetadata<T: Decodable & Sendable>(
        contextId: String,
        method: String,
        argsJson: [String: JSONValue] = [:]
    ) async throws -> RpcExecuteResult<T> {
        let returns: T = try await execute(contextId: contextId, method: method, argsJson: argsJson)
        return RpcExecuteResult(returns: returns, transport: .node)
    }

    /// A readable message for an error object that carries only `type`/`data`
    /// (core serializes `ExecutionError` that way).
    static func describe(type: String?, data: JSONValue?) -> String? {
        guard let type else { return nil }
        if type == RpcError.readOnlyWriteRefusedType {
            var context = ""
            if case .object(let obj)? = data, case .string(let id)? = obj["context_id"] { context = " on \(id)" }
            return "write refused\(context): this node only holds a read-only replica of the context"
        }
        // The reason is in `data` (a string, or a nested object); without
        // it the message would be the bare type, e.g. "FunctionCallError".
        if let detail = RpcError.text(of: data) { return "\(type): \(detail)" }
        return type
    }

    /// One-tap owner-driven convert: re-signs the caller's identity-gated entries
    /// to the current schema in a single sweep (does not loop).
    public func migrateMyEntries(_ contextId: String) async throws -> MigrateMyEntriesSummary {
        try await execute(contextId: contextId, method: "migrate_my_entries")
    }

    /// Read-only count of the caller's entries still below the target schema.
    public func countMyPending(_ contextId: String) async throws -> Int {
        try await execute(contextId: contextId, method: "count_my_pending")
    }
}
