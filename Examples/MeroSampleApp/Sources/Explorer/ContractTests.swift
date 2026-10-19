import Foundation
import MeroKit

/// The scaffolding-e2e contract tests, run from a JSON spec shared with the
/// Kotlin sample (`Resources/contract-tests.json`, ported from
/// `apps/scaffolding-e2e`'s TestRunner). Each case is a list of contract calls,
/// each with one expectation; `${run}` is a per-run prefix and `${name}` a value
/// an earlier step saved. See the spec's `ops` and `conventions`.
struct ContractSpec: Decodable {
    struct Case: Decodable {
        let id: String
        let name: String
        let group: String
        let steps: [JSONValue]
    }
    let package: String
    let cases: [Case]

    static func load() -> ContractSpec? {
        guard let url = Bundle.main.url(forResource: "contract-tests", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ContractSpec.self, from: data)
    }
}

/// Runs one spec case against a context, with the run's shared prefix.
struct ContractCaseRunner {
    let mero: Mero
    let contextId: String
    let run: String

    /// Nil when the case passed, else why it failed.
    func run(_ testCase: ContractSpec.Case) async -> String? {
        var vars: [String: Any] = [:]
        for (index, stepValue) in testCase.steps.enumerated() {
            guard let step = Self.any(stepValue) as? [String: Any], let method = step["call"] as? String,
                let expect = step["expect"] as? [String: Any], let op = expect["op"] as? String
            else { return "step \(index + 1): malformed" }
            let args = substitute(step["args"] ?? [String: Any](), vars) as? [String: Any] ?? [:]
            var output: Any = NSNull()
            var failure: String?
            do {
                let json = try JSONSerialization.data(withJSONObject: args)
                let decoded = try JSONDecoder().decode([String: JSONValue].self, from: json)
                let value: JSONValue = try await mero.rpc.execute(
                    contextId: contextId, method: method, argsJson: decoded)
                output = Self.any(value)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            if let path = step["path"] as? String, failure == nil {
                output = Self.select(output, path: substitute(path, vars) as? String ?? path)
            }
            let expectation = substitute(expect, vars) as? [String: Any] ?? expect
            if let why = check(op, expectation, output: output, failure: failure) {
                return "step \(index + 1) \(method): \(why)"
            }
            if let name = step["save"] as? String { vars[name] = output }
        }
        return nil
    }

    // MARK: expectations

    private func check(_ op: String, _ e: [String: Any], output: Any, failure: String?) -> String? {
        switch op {
        case "any": return nil
        case "error": return failure == nil ? "expected an error, got \(Self.show(output))" : nil
        case "okOrErrorMatches":
            guard let failure else { return nil }
            let pattern = e["pattern"] as? String ?? ""
            return failure.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil
                ? "error \"\(failure)\" does not match /\(pattern)/" : nil
        default: break
        }
        if let failure { return failure }
        let value = e["value"]
        if ["contains", "containsWhere", "notContainsWhere", "isSorted", "hasKey", "matches", "nonEmptyString"]
            .contains(op)
        {
            return checkCollection(op, e, output: output)
        }
        switch op {
        case "noError": return nil
        case "eq": return Self.equal(output, value) ? nil : "expected \(Self.show(value)), got \(Self.show(output))"
        case "neq": return Self.equal(output, value) ? "expected anything but \(Self.show(value))" : nil
        case "isNull": return output is NSNull ? nil : "expected null, got \(Self.show(output))"
        case "notNull": return output is NSNull ? "expected a value, got null" : nil
        case "isArray": return output is [Any] ? nil : "expected an array, got \(Self.show(output))"
        case "isObject": return output is [String: Any] ? nil : "expected an object, got \(Self.show(output))"
        case "isTrue": return Self.bool(output) == true ? nil : "expected true, got \(Self.show(output))"
        case "isFalse": return Self.bool(output) == false ? nil : "expected false, got \(Self.show(output))"
        case "gte", "gt", "lt", "lte":
            guard let a = Self.number(output), let b = Self.number(value) else {
                return "expected numbers, got \(Self.show(output)) and \(Self.show(value))"
            }
            let ok = op == "gte" ? a >= b : op == "gt" ? a > b : op == "lt" ? a < b : a <= b
            return ok ? nil : "expected \(Self.show(output)) \(op) \(Self.show(value))"
        default:
            return "unknown op \(op)"
        }
    }

    private func checkCollection(_ op: String, _ e: [String: Any], output: Any) -> String? {
        let value = e["value"]
        switch op {
        case "nonEmptyString":
            return (output as? String).map { $0.isEmpty ? "expected a non-empty string" : nil }
                ?? "expected a string, got \(Self.show(output))"
        case "matches":
            let pattern = e["pattern"] as? String ?? ""
            guard let text = output as? String, text.range(of: pattern, options: .regularExpression) != nil else {
                return "expected /\(pattern)/, got \(Self.show(output))"
            }
            return nil
        case "hasKey":
            let key = e["key"] as? String ?? ""
            return (output as? [String: Any])?[key] != nil ? nil : "no key \(key) in \(Self.show(output))"
        case "contains":
            if let text = output as? String, let needle = value as? String {
                return text.contains(needle) ? nil : "\"\(text)\" does not contain \"\(needle)\""
            }
            if let array = output as? [Any] {
                return array.contains { Self.equal($0, value) }
                    ? nil : "\(Self.show(value)) not in \(Self.show(output))"
            }
            return "expected a string or array, got \(Self.show(output))"
        case "containsWhere", "notContainsWhere":
            let key = e["key"] as? String ?? ""
            let found = (output as? [Any] ?? []).contains { Self.equal(($0 as? [String: Any])?[key], value) }
            return found == (op == "containsWhere")
                ? nil : "\(op) \(key)=\(Self.show(value)) failed on \(Self.show(output))"
        case "isSorted":
            guard let array = output as? [String] else { return "expected an array of strings" }
            return array
                == array.sorted {
                    Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes(
                        $1.unicodeScalars.map(\.value))
                } ? nil : "not sorted: \(Self.show(output))"
        default:
            return "unknown op \(op)"
        }
    }

    // MARK: substitution and paths

    private func substitute(_ node: Any, _ vars: [String: Any]) -> Any {
        if let text = node as? String {
            if let exact = exactVar(text, vars) { return exact }
            var out = text.replacingOccurrences(of: "${run}", with: run)
            for (name, value) in vars { out = out.replacingOccurrences(of: "${\(name)}", with: Self.plain(value)) }
            return out
        }
        if let dict = node as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict { out[substitute(key, vars) as? String ?? key] = substitute(value, vars) }
            return out
        }
        if let array = node as? [Any] { return array.map { substitute($0, vars) } }
        return node
    }

    /// `"${name}"`, `"${name}+N"` or `"${name}-N"` → the saved value, typed.
    private func exactVar(_ text: String, _ vars: [String: Any]) -> Any? {
        guard let match = text.firstMatch(of: /^\$\{(\w+)\}([+-]\d+)?$/), String(match.1) != "run",
            let saved = vars[String(match.1)]
        else { return nil }
        guard let offset = match.2.flatMap({ Int($0) }) else { return saved }
        guard let n = Self.number(saved) else { return saved }
        return NSNumber(value: n + Double(offset))
    }

    static func select(_ node: Any, path: String) -> Any {
        var current: Any = node
        for segment in path.split(separator: ".").map(String.init) {
            if segment == "length" {
                if let a = current as? [Any] { current = a.count; continue }
                if let s = current as? String { current = s.count; continue }
                if let d = current as? [String: Any] { current = d.count; continue }
            }
            if let index = Int(segment), let array = current as? [Any] {
                let i = index < 0 ? array.count + index : index
                current = array.indices.contains(i) ? array[i] : NSNull()
            } else if let dict = current as? [String: Any] {
                current = dict[segment] ?? NSNull()
            } else {
                return NSNull()
            }
        }
        return current
    }

    // MARK: JSON helpers

    static func any(_ value: JSONValue) -> Any {
        guard let data = try? JSONEncoder().encode(value),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return NSNull() }
        return object
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        let left = a ?? NSNull()
        let right = b ?? NSNull()
        if let x = number(left), let y = number(right), !(left is String), !(right is String) { return x == y }
        return (left as AnyObject).isEqual(right)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return nil
    }

    static func bool(_ value: Any) -> Bool? {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }

    static func plain(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = number(value) { return n == n.rounded() ? String(Int(n)) : String(n) }
        return show(value)
    }

    static func show(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let s = value as? String { return "\"\(s)\"" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            return text.count > 160 ? String(text.prefix(160)) + "…" : text
        }
        return "\(value)"
    }
}
