import Foundation
import XCTest

@testable import MeroKit

/// Loads a response body captured verbatim from a live node at the core release
/// pinned in `ci/core-version`.
///
/// A fixture written by hand to match the model can only confirm the model
/// agrees with itself — see `Fixtures/README.md` for the two breaks that got
/// through exactly that way.
enum Fixture {
    static func json(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws
        -> String
    {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        else {
            XCTFail("fixture \(name).json is not in the test bundle", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func data(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws
        -> Data
    {
        Data(try json(name, file: file, line: line).utf8)
    }

    static func decode<T: Decodable>(
        _ type: T.Type, _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> T {
        try JSONDecoder().decode(type, from: try data(name, file: file, line: line))
    }

    /// The fixture as a plain JSON object, for key-level comparisons.
    static func object(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws
        -> [String: JSONValue]
    {
        try decode([String: JSONValue].self, name, file: file, line: line)
    }
}
