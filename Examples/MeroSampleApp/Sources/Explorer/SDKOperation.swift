import Foundation
import MeroKit

/// One input field for an operation form.
struct OpField: Identifiable, Sendable {
    enum Kind: Sendable { case line, multiline }
    let id: String
    let label: String
    let placeholder: String
    let kind: Kind

    static func line(_ id: String, _ label: String, _ ph: String = "") -> OpField {
        OpField(id: id, label: label, placeholder: ph, kind: .line)
    }
    static func json(_ id: String = "body", _ label: String = "Request JSON", _ ph: String = "{}") -> OpField {
        OpField(id: id, label: label, placeholder: ph, kind: .multiline)
    }
}

/// A single invokable SDK method: metadata + input fields + an async runner that
/// returns a rendered (pretty-printed) result string.
struct SDKOperation: Identifiable, Sendable {
    let id: String
    let category: String
    let name: String
    let summary: String
    let fields: [OpField]
    let run: @Sendable (Mero, [String: String]) async throws -> String
}

// MARK: - Rendering / decoding helpers

enum Fmt {
    static func json<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(value), let str = String(data: data, encoding: .utf8) { return str }
        return String(describing: value)
    }

    /// Decode a user-entered JSON string into a request type (empty → `{}`).
    static func decode<T: Decodable>(_ s: String, _ type: T.Type) throws -> T {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode(T.self, from: Data((text.isEmpty ? "{}" : text).utf8))
    }
}

extension Dictionary where Key == String, Value == String {
    /// Trimmed value for a field id (empty string if absent).
    func v(_ key: String) -> String { (self[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Optional trimmed value (nil if empty).
    func opt(_ key: String) -> String? { let s = v(key); return s.isEmpty ? nil : s }
}
