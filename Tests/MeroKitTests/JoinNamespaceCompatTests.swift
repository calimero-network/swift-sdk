import XCTest

@testable import MeroKit

/// core 0.11.0-rc.25 (core#3598) renamed the namespace-join response field from
/// `groupId` to `namespaceId`. Declared non-optional, that threw `keyNotFound`
/// on every rc.25 join, so `joinNamespace` failed outright — a hard break, not a
/// degradation. Both spellings are pinned here so neither direction regresses.
final class JoinNamespaceCompatTests: XCTestCase {

    private func decode(_ json: String) throws -> JoinNamespaceResponseData {
        try JSONDecoder().decode(JoinNamespaceResponseData.self, from: Data(json.utf8))
    }

    func testDecodesTheRc25Spelling() throws {
        let data = try decode(
            #"{"namespaceId":"ns-1","memberIdentity":"id-1","memberAccount":"acct-1"}"#)
        XCTAssertEqual(data.namespaceId, "ns-1")
        XCTAssertEqual(data.memberIdentity, "id-1")
        XCTAssertEqual(data.memberAccount, "acct-1")
    }

    func testDecodesThePreRc25Spelling() throws {
        let data = try decode(#"{"groupId":"ns-1","memberIdentity":"id-1"}"#)
        XCTAssertEqual(data.namespaceId, "ns-1")
        XCTAssertNil(data.memberAccount)
    }

    func testPrefersTheNewSpellingWhenANodeSendsBoth() throws {
        let data = try decode(
            #"{"namespaceId":"new","groupId":"old","memberIdentity":"id-1"}"#)
        XCTAssertEqual(data.namespaceId, "new")
    }

    func testAMissingMemberAccountIsNotFatal() throws {
        // rc.21 introduced memberAccount; older nodes omit it.
        let data = try decode(#"{"namespaceId":"ns","memberIdentity":"id"}"#)
        XCTAssertNil(data.memberAccount)
    }

    func testFailsClearlyWhenNeitherSpellingIsPresent() {
        XCTAssertThrowsError(try decode(#"{"memberIdentity":"id-1"}"#)) { error in
            guard case DecodingError.keyNotFound(_, let context) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("namespaceId"))
            XCTAssertTrue(context.debugDescription.contains("groupId"))
        }
    }

    func testRoundTripsThroughTheNewSpelling() throws {
        let original = JoinNamespaceResponseData(
            namespaceId: "ns", memberIdentity: "id", memberAccount: "acct")
        let encoded = try JSONEncoder().encode(original)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("namespaceId"))
        XCTAssertEqual(try JSONDecoder().decode(JoinNamespaceResponseData.self, from: encoded).namespaceId, "ns")
    }
}
