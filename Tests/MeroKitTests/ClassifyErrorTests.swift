import XCTest

@testable import MeroKit

/// What a failed request means. (Port of mero-js `errors/classify.test.ts`.)
final class ClassifyErrorTests: XCTestCase {
    private func httpError(_ status: Int, _ error: String? = nil) -> MeroError {
        let body = error.map { #"{"error":"\#($0)"}"# }
        return .http(
            HTTPError(
                status: status, statusText: "Status", url: "http://node/admin-api/x", headers: [:], bodyText: body))
    }

    func testStatusTable() {
        struct Row {
            let status: Int
            let kind: ErrorKind
            let retryable: Bool
        }
        let table: [Row] = [
            Row(status: 400, kind: .invalid, retryable: false),
            Row(status: 401, kind: .unauthorized, retryable: true),
            Row(status: 403, kind: .forbidden, retryable: false),
            Row(status: 404, kind: .notFound, retryable: true),
            Row(status: 409, kind: .conflict, retryable: false),
            Row(status: 410, kind: .gone, retryable: false),
            Row(status: 413, kind: .tooLarge, retryable: false),
            Row(status: 422, kind: .invalid, retryable: false),
            Row(status: 429, kind: .rateLimited, retryable: true),
            Row(status: 500, kind: .server, retryable: true),
            Row(status: 502, kind: .server, retryable: true),
            Row(status: 503, kind: .unavailable, retryable: true),
            Row(status: 504, kind: .unavailable, retryable: true),
            Row(status: 0, kind: .unreachable, retryable: true),
        ]
        for row in table {
            let classified = classifyError(httpError(row.status, "no"))
            XCTAssertEqual(classified.kind, row.kind, "\(row.status)")
            XCTAssertEqual(classified.status, row.status, "\(row.status)")
            XCTAssertEqual(classified.retryable, row.retryable, "\(row.status)")
        }
    }

    func testKindRawValuesAreMeroJsStrings() {
        XCTAssertEqual(ErrorKind.notFound.rawValue, "not-found")
        XCTAssertEqual(ErrorKind.tooLarge.rawValue, "too-large")
        XCTAssertEqual(ErrorKind.rateLimited.rawValue, "rate-limited")
        XCTAssertEqual(ErrorKind.allCases.count, 12)
    }

    /// The status line is what `HTTPError.message` says; a UI showing detail
    /// wants what the node actually said.
    func testGivesTheNodesExplanationWithoutTheStatusPrefix() {
        let err = httpError(409, "invitation for group ab12 expired at 1759000000 (unix seconds)")
        XCTAssertEqual(
            classifyError(err).message, "invitation for group ab12 expired at 1759000000 (unix seconds)")
    }

    func testFallsBackToTheStatusLineWhenTheBodySaidNothing() {
        XCTAssertEqual(classifyError(httpError(500)).message, "HTTP 500 Status")
    }

    func testReadsAStatusZeroErrorsTextAsItsExplanation() {
        let err = HTTPError(
            status: 0, statusText: "Network Error", url: "http://node/x", headers: [:], bodyText: "Failed to fetch")
        let classified = classifyError(err)
        XCTAssertEqual(classified.kind, .unreachable)
        XCTAssertEqual(classified.message, "Failed to fetch")
    }

    func testReadsNestedAndDetailExplanations() {
        let nested = HTTPError(
            status: 403, statusText: "Forbidden", url: "u", headers: [:],
            bodyText: #"{"error":{"message":"not a member"}}"#)
        XCTAssertEqual(classifyError(nested).message, "not a member")
        let detail = HTTPError(
            status: 403, statusText: "Forbidden", url: "u", headers: [:],
            bodyText: #"{"detail":"account is not linked"}"#)
        XCTAssertEqual(classifyError(detail).message, "account is not linked")
    }

    func testARevokedFamilyReadsByItsStatus() {
        let http = HTTPError(
            status: 401, statusText: "Unauthorized", url: "u", headers: ["x-auth-error": "token_reuse"])
        let classified = classifyError(MeroError.authRevoked(reason: "token_reuse", http: http))
        XCTAssertEqual(classified.kind, .unauthorized)
        XCTAssertEqual(classified.status, 401)
    }

    /// The transport's own status-0 failure.
    func testANetworkFailureIsUnreachable() {
        let classified = classifyError(MeroError.network("The Internet connection appears to be offline."))
        XCTAssertEqual(
            classified,
            ClassifiedError(
                kind: .unreachable, status: 0, retryable: true,
                message: "The Internet connection appears to be offline."))
    }

    /// The analog of mero-js's `TypeError: Failed to fetch`.
    func testARawURLErrorIsUnreachableWithNoStatus() {
        let classified = classifyError(URLError(.notConnectedToInternet))
        XCTAssertEqual(classified.kind, .unreachable)
        XCTAssertNil(classified.status)
        XCTAssertTrue(classified.retryable)
        XCTAssertEqual(classifyError(URLError(.cancelled)).kind, .unknown)
    }

    func testABareHTTPErrorIsClassifiedLikeTheWrappedOne() {
        let classified = classifyError(HTTPError(status: 413, statusText: "Too Large", url: "u", headers: [:]))
        XCTAssertEqual(classified.kind, .tooLarge)
        XCTAssertEqual(classified.status, 413)
    }

    func testAccountErrors() {
        let nonce = classifyError(AccountError.intentRefused(reason: "nonce spent", retryable: true, status: 403))
        XCTAssertEqual(nonce.kind, .forbidden)
        XCTAssertTrue(nonce.retryable, "a nonce refusal is one recovery can fix")
        XCTAssertEqual(nonce.message, "nonce spent")
        let refused = classifyError(AccountError.intentRefused(reason: "no", retryable: false, status: 403))
        XCTAssertFalse(refused.retryable)
        let ha = classifyError(AccountError.haRefused(code: "unknown_relay", status: 409, body: nil))
        XCTAssertEqual(ha.kind, .conflict)
        XCTAssertEqual(classifyError(AccountError.invalidInput("bad hex")).kind, .invalid)
        XCTAssertFalse(classifyError(AccountError.stateMismatch).retryable)
        XCTAssertEqual(classifyError(AccountError.enrolmentDeclined("no")).kind, .forbidden)
        XCTAssertEqual(classifyError(AccountError.notSignedIn("sign in")).kind, .unauthorized)
        XCTAssertEqual(classifyError(AccountError.relayKeyUnavailable("no quote")).kind, .unavailable)
    }

    func testKeepsAnythingElseRetryableWithItsMessage() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        XCTAssertEqual(
            classifyError(Boom()), ClassifiedError(kind: .unknown, status: nil, retryable: true, message: "boom"))
        let rpc = classifyError(MeroError.rpc(RpcError(code: -32000, message: "contract panicked")))
        XCTAssertEqual(rpc.kind, .unknown)
        XCTAssertEqual(rpc.message, "contract panicked")
        XCTAssertFalse(classifyError(MeroError.decoding("x")).message.isEmpty)
    }
}
