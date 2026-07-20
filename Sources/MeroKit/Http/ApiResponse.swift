import Foundation

/// The `{ data, error }` envelope core wraps most admin/auth payloads in.
/// (== mero-js `ApiResponse<T>`.)
public struct ApiResponse<T: Codable & Sendable>: Codable, Sendable {
    public let data: T?
    public let error: String?
}

/// A decodable placeholder for endpoints with no meaningful body (204/empty 2xx).
public struct Empty: Codable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws { self.init() }
    public func encode(to encoder: Encoder) throws {}
}

/// Shared JSON coders. Bodies use explicit `CodingKeys` per DTO (the wire naming
/// is inconsistent), so no global key strategy is applied here.
public enum MeroJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
