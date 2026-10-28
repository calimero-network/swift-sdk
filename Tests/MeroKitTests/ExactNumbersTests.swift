import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A generated client's `u64`s (nanosecond timestamps, `u64::MAX`) cross the
/// bound adapter and the relay as text, digit for digit: never through
/// ``JSONValue``'s `Double`.
final class ExactNumbersTests: XCTestCase {
    private let context = DelegatedFixture.rep("11")
    /// Canonical: keys sorted, no whitespace.
    private let exact = #"{"at":1761650000123456789,"max":18446744073709551615}"#
    private let sent = #"{ "max": 18446744073709551615, "at": 1761650000123456789 }"#

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func relay(token: String?) -> RelayClient {
        let cb = DelegatedFixture.enrolled
        return RelayClient(
            relayURL: DelegatedFixture.relay, authorAccount: cb.account, authorProof: cb.credential,
            keys: DelegatedFixture.keys, nonces: MemoryWarrantNonceStore(), tokenProvider: { token },
            session: MockURLProtocol.makeSession())
    }

    func testU64sRoundTripThroughAWarrantExactly() async throws {
        let rig = CloudRig()
        DelegatedFixture.serveDescribe(rig, ctx: context)
        rig.on("POST", "/admin-api/contexts/\(context)/intents", json: #"{"data":{"returns":\#(exact),"rootHash":"r"}}"#)
        rig.install()

        let bound = RelayContextContract(relay: relay(token: nil)).bound(to: context)
        let answer = try await bound.execute(method: "stamp", argsJSON: Data(sent.utf8))

        XCTAssertEqual(String(decoding: answer, as: UTF8.self), exact)
        let posted = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(context)/intents").first)
        let body = String(decoding: posted.body, as: UTF8.self)
        XCTAssertTrue(body.contains(#""argsJson":\#(exact)"#), body)
        // The warrant commits to exactly those bytes.
        let warrant = try XCTUnwrap(LiteralJSON.parse(posted.body)["warrant"])
        guard case .string(let hex) = warrant else { return XCTFail("no warrant") }
        let hash = Warrants.intentHash(method: "stamp", canonicalArgs: Data(exact.utf8))
        XCTAssertTrue(hex.contains(Hex.encode(hash)), "the warrant's intentHash is over the exact args")
    }

    func testU64sRoundTripThroughTheQueryExactly() async throws {
        let rig = CloudRig()
        rig.on("POST", "/admin-api/contexts/\(context)/query", json: #"{"data":{"returns":\#(exact)}}"#)
        rig.install()

        let bound = RelayContextContract(relay: relay(token: "t")).bound(to: context)
        let answer = try await bound.query(method: "stamps", argsJSON: Data(sent.utf8))

        XCTAssertEqual(String(decoding: answer, as: UTF8.self), exact)
        let posted = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(context)/query").first)
        XCTAssertEqual(
            String(decoding: posted.body, as: UTF8.self), #"{"argsJson":\#(exact),"method":"stamps"}"#)
        XCTAssertEqual(posted.headers["authorization"], "Bearer t")
    }

    func testU64sRoundTripThroughTheRecordingContractExactly() async throws {
        let contract = RecordingContextContract()
        contract.setRawHandler { $0.argsJSON }
        let answer = try await contract.bound(to: context).query(method: "echo", argsJSON: Data(sent.utf8))
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), exact)
        XCTAssertEqual(contract.calls.first?.argsJSON, Data(exact.utf8))
    }

    func testTheRelaylessContractStillNamesTheMethod() async {
        do {
            _ = try await NoRelayContextContract().bound(to: context).query(method: "stamps", argsJSON: Data(sent.utf8))
            XCTFail("expected noRelay")
        } catch AccountError.noRelay(let method) {
            XCTAssertEqual(method, "stamps")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCanonicalSpellingMatchesCanonicalJSONBesideTheIntegers() throws {
        let input = #" { "b" : 1, "a" : [1.50, -0, 1e3, "x\u00e9\n\/", true, null, {}] } "#
        let literal = String(decoding: try LiteralJSON.canonical(Data(input.utf8)), as: UTF8.self)
        XCTAssertEqual(literal, #"{"a":[1.5,0,1000,"xé\n/",true,null,{}],"b":1}"#)
        let viaValue = CanonicalJSON.string(try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8)))
        XCTAssertEqual(literal, viaValue, "below 2^53 both spellings agree, so warrants hash the same bytes")
    }

    func testSurrogatePairsAndRefusals() throws {
        let pair = try LiteralJSON.canonical(Data(#""\ud83d\ude00""#.utf8))
        XCTAssertEqual(String(decoding: pair, as: UTF8.self), "\"😀\"")
        for bad in ["{", "[1,]", "01", "1.", "\"\\x\"", "{\"a\" 1}", "1 2", "\"\\ud83d\""] {
            XCTAssertThrowsError(try LiteralJSON.canonical(Data(bad.utf8)), bad)
        }
    }
}
