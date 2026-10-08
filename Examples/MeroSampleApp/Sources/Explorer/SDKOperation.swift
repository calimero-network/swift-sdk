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

/// What a Cloud / relay operation runs against.
struct CloudOpContext: Sendable {
    let signIn: CloudSignIn
    /// `nil` when the account has no relay yet.
    let relay: RelayClient?
    let session: CloudSession?

    func requireRelay() throws -> RelayClient {
        guard let relay else { throw AccountError.notSignedIn("No relay serves this account yet.") }
        return relay
    }
}

/// A single invokable SDK method: metadata + input fields + an async runner that
/// returns a rendered (pretty-printed) result string.
///
/// Node-admin operations run against the session's `Mero` (on a Cloud session,
/// the relay's Bearer session). Cloud / relay operations run against the
/// account layer instead (`cloudRun`).
struct SDKOperation: Identifiable, Sendable {
    let id: String
    let category: String
    let name: String
    let summary: String
    let fields: [OpField]
    let run: @Sendable (Mero, [String: String]) async throws -> String
    let cloudRun: (@Sendable (CloudOpContext, [String: String]) async throws -> String)?

    init(
        id: String, category: String, name: String, summary: String, fields: [OpField],
        run: @escaping @Sendable (Mero, [String: String]) async throws -> String
    ) {
        self.id = id; self.category = category; self.name = name; self.summary = summary
        self.fields = fields; self.run = run; self.cloudRun = nil
    }

    private init(
        id: String, category: String, name: String, summary: String, fields: [OpField],
        cloudRun: @escaping @Sendable (CloudOpContext, [String: String]) async throws -> String
    ) {
        self.id = id; self.category = category; self.name = name; self.summary = summary
        self.fields = fields
        self.run = { _, _ in throw AccountError.notSignedIn("a Cloud operation") }
        self.cloudRun = cloudRun
    }

    /// An operation on the account layer (Cloud manager, relay, warrants).
    static func cloud(
        id: String, name: String, summary: String, fields: [OpField] = [],
        category: String = "Cloud & Relay",
        _ run: @escaping @Sendable (CloudOpContext, [String: String]) async throws -> String
    ) -> SDKOperation {
        SDKOperation(id: id, category: category, name: name, summary: summary, fields: fields, cloudRun: run)
    }
}

// MARK: - Rendering / decoding helpers

enum Fmt {
    /// Parse a JSON field into a `JSONValue` (empty → `{}`).
    static func value(_ s: String) throws -> JSONValue {
        try decode(s, JSONValue.self)
    }

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
