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
}

/// The result of ``RpcClient/executeWithMetadata(contextId:method:argsJson:)``.
public struct RpcExecuteResult<T: Sendable>: Sendable {
    public let returns: T
    public let transport: RpcTransportKind
    public init(returns: T, transport: RpcTransportKind) {
        self.returns = returns
        self.transport = transport
    }
}

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

        guard let output = decoded.result?.output else {
            throw MeroError.emptyResponse("JSON-RPC result had no output")
        }
        return output
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
        if case .string(let detail)? = data { return "\(type): \(detail)" }
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
