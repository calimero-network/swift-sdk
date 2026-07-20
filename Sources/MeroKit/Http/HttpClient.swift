import Foundation

/// HTTP verbs used by the SDK.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
}

/// A request body. Blobs use `.file`/`.data` (raw octet-stream); JSON calls use `.json`.
public enum HttpBody: Sendable {
    /// Pre-encoded JSON bytes; sent with `Content-Type: application/json`.
    case json(Data)
    /// Raw bytes with an explicit content type.
    case data(Data, contentType: String)
    /// A file streamed from disk with an explicit content type (memory-safe for large blobs).
    case file(URL, contentType: String)
}

/// A single HTTP request. `parse: json` is implied by the typed `send` methods.
public struct HttpRequest: Sendable {
    public var path: String
    public var method: HTTPMethod
    public var body: HttpBody?
    public var headers: [String: String]
    public var timeout: TimeInterval?

    public init(
        path: String,
        method: HTTPMethod = .get,
        body: HttpBody? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.path = path
        self.method = method
        self.body = body
        self.headers = headers
        self.timeout = timeout
    }
}

/// Result of a `HEAD` (or the metadata half of a raw response). Header keys are lowercased.
public struct HeadResult: Sendable {
    public let status: Int
    public let headers: [String: String]

    public init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }
}

/// The transport contract every API client (`AuthApi`, `AdminApi`, `RpcClient`)
/// depends on. (== the `HttpClient` interface in mero-js `http-types.ts`.)
public protocol HttpClient: Sendable {
    /// Send and JSON-decode into `T`. Empty 2xx bodies decode to `Empty`/optionals; otherwise throw.
    func send<T: Decodable>(_ req: HttpRequest) async throws -> T
    /// Send and ignore the response body.
    func sendVoid(_ req: HttpRequest) async throws
    /// Send and return the raw bytes plus response metadata (for blobs).
    func sendRaw(_ req: HttpRequest) async throws -> (Data, HeadResult)
    /// A `HEAD` request returning status + headers only.
    func head(_ path: String, headers: [String: String]) async throws -> HeadResult
    /// Stream a `GET` (or given method) response body directly to `fileURL` (memory-safe download).
    func download(_ req: HttpRequest, to fileURL: URL) async throws -> HeadResult
}

// MARK: - Convenience verbs

public extension HttpClient {
    func get<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        try await send(HttpRequest(path: path, method: .get, headers: headers))
    }

    func post<T: Decodable>(
        _ path: String, json body: some Encodable, headers: [String: String] = [:]
    ) async throws -> T {
        try await send(HttpRequest(path: path, method: .post, body: .json(try MeroJSON.encode(body)), headers: headers))
    }

    func post<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        try await send(HttpRequest(path: path, method: .post, headers: headers))
    }

    func put<T: Decodable>(_ path: String, json body: some Encodable, headers: [String: String] = [:]) async throws -> T
    {
        try await send(HttpRequest(path: path, method: .put, body: .json(try MeroJSON.encode(body)), headers: headers))
    }

    func put<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        try await send(HttpRequest(path: path, method: .put, headers: headers))
    }

    func patch<T: Decodable>(
        _ path: String, json body: some Encodable, headers: [String: String] = [:]
    ) async throws -> T {
        try await send(
            HttpRequest(path: path, method: .patch, body: .json(try MeroJSON.encode(body)), headers: headers))
    }

    func delete<T: Decodable>(_ path: String, headers: [String: String] = [:]) async throws -> T {
        try await send(HttpRequest(path: path, method: .delete, headers: headers))
    }

    func delete<T: Decodable>(
        _ path: String, json body: some Encodable, headers: [String: String] = [:]
    ) async throws -> T {
        try await send(
            HttpRequest(path: path, method: .delete, body: .json(try MeroJSON.encode(body)), headers: headers))
    }
}
