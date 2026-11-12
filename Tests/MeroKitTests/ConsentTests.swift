import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The consent kinds that make something (`createOrg`, `createInvite`,
/// `acceptInvite`), their typed outcomes, and the check that a return from the
/// consent page decided the request this app started; against a
/// ``FakeCloudNode`` (the real sealed channel).
final class ConsentTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> CalimeroClient {
        CalimeroClient(
            CalimeroClientOptions(
                baseUrl: "https://node.test", policy: CloudPolicy(allowMock: true),
                session: MockURLProtocol.makeSession(), retry: CloudRetryOptions(retries: 3)),
            sleep: { _ in })
    }

    /// A node that starts request `r1` and answers `result` for it.
    @discardableResult
    private func serve(result: JSONValue) -> FakeCloudNode {
        let node = FakeCloudNode { request in
            switch (request.method, request.path) {
            case ("POST", "/consent/requests"):
                return .json([
                    "requestId": "r1", "url": "https://node.test/consent/r1", "expiresAt": 1_900_000_000,
                    "code": .string(confirmationCode("r1")),
                ])
            case ("GET", "/consent/r1/result"): return .json(result)
            default: return .error(404, "NOT_FOUND")
            }
        }
        node.install()
        return node
    }

    private static let returnTo = "https://chat.example/1.0.0/?native-consent=1"

    func testTheNewKindsBodiesAreCores() {
        let returnTo = Self.returnTo
        XCTAssertEqual(
            ConsentRequest.createOrg(name: "Acme", returnTo: returnTo).json,
            ["kind": "createOrg", "subject": ["name": "Acme"], "returnTo": .string(returnTo)])
        XCTAssertEqual(
            ConsentRequest.createInvite(org: "o1", role: .member, returnTo: returnTo).json,
            ["kind": "createInvite", "subject": ["org": "o1", "role": "member"], "returnTo": .string(returnTo)])
        XCTAssertEqual(
            ConsentRequest.createInvite(
                org: "o1", role: .admin, teams: ["t1"], ttlSecs: 3600, uses: 5, allApps: true, returnTo: returnTo
            ).json,
            [
                "kind": "createInvite",
                "subject": [
                    "org": "o1", "role": "admin", "teams": ["t1"], "ttlSecs": 3600, "uses": 5, "allApps": true,
                ],
                "returnTo": .string(returnTo),
            ])
        XCTAssertEqual(
            ConsentRequest.acceptInvite(token: "inv_secret", returnTo: returnTo).json,
            ["kind": "acceptInvite", "subject": ["token": "inv_secret"], "returnTo": .string(returnTo)])
        XCTAssertEqual(ConsentRequest.acceptInvite(token: "t", returnTo: returnTo).kind, "acceptInvite")
        XCTAssertEqual(ConsentRequest.upgrade(app: "a1", toVersion: "1.1.0", returnTo: returnTo).returnTo, returnTo)
    }

    func testTheGeneratedBodyRefusesTheKindsItDoesNotKnow() throws {
        XCTAssertThrowsError(try ConsentRequest.createOrg(name: "Acme", returnTo: Self.returnTo).generated())
        XCTAssertNoThrow(try ConsentRequest.upgrade(app: "a1", toVersion: "1.1.0", returnTo: Self.returnTo).generated())
    }

    func testCreatesAnOrganizationAndReadsItsIdFromTheSealedResult() async throws {
        let node = serve(result: [
            "requestId": "r1", "kind": "createOrg", "status": "approved", "decidedAt": 2, "outcome": ["orgId": "o9"],
        ])
        let cloud = client()
        let started = try await cloud.requestConsent(.createOrg(name: "Acme", returnTo: Self.returnTo))
        XCTAssertEqual(started.requestId, "r1")
        XCTAssertEqual(started.code, confirmationCode("r1"))
        let body = try XCTUnwrap(node.requests.first { $0.path == "/consent/requests" }?.json)
        XCTAssertEqual(body["kind"], "createOrg")
        XCTAssertEqual(body["subject"]?["name"], "Acme")

        let returned = try XCTUnwrap(URL(string: "\(Self.returnTo)&request_id=r1&result=approved"))
        let result = try await cloud.confirmConsentReturn(started, returned: returned)
        XCTAssertTrue(result.isApproved)
        XCTAssertEqual(result.outcome, .orgCreated(orgId: "o9"))
        XCTAssertEqual(result.orgId, "o9")
        XCTAssertNil(result.inviteToken)
        XCTAssertEqual(node.requests.last?.path, "/consent/r1/result", "read from the sealed result")
    }

    func testOpenConsentPageAndWaitForConsentKnowTheNewKinds() async throws {
        serve(result: [
            "requestId": "r1", "kind": "acceptInvite", "status": "approved", "decidedAt": 2, "outcome": ["org": "o1"],
        ])
        let cloud = client()
        let opened = Box<[URL]>([])
        let started = try await cloud.openConsentPage(.acceptInvite(token: "inv_x", returnTo: Self.returnTo)) { url in
            opened.update { $0.append(url) }
        }
        XCTAssertEqual(opened.get, [URL(string: "https://node.test/consent/r1")!])
        let result = try await cloud.waitForConsent(started.requestId)
        XCTAssertEqual(result.joinedOrg, "o1")
        XCTAssertEqual(result.outcome, .inviteAccepted(org: "o1"))
    }

    func testAnInviteTokenIsTypedAndNeverDescribed() async throws {
        serve(result: [
            "requestId": "r1", "kind": "createInvite", "status": "approved", "decidedAt": 2,
            "outcome": ["token": "inv_secret_123"],
        ])
        let result = try await client().consentResult("r1")
        XCTAssertEqual(result.inviteToken, "inv_secret_123")

        let request = ConsentRequest.acceptInvite(token: "inv_secret_123", returnTo: Self.returnTo)
        let outcome = try XCTUnwrap(result.outcome)
        var dumped = ""
        dump(result, to: &dumped)
        dump(request, to: &dumped)
        dump(outcome, to: &dumped)
        let texts = [
            String(describing: result), String(reflecting: result), "\(result)", String(describing: request),
            String(reflecting: request), String(describing: outcome), String(reflecting: outcome),
            String(describing: Optional(outcome)), String(describing: [result]), dumped,
        ]
        for text in texts {
            XCTAssertFalse(text.contains("inv_secret_123"), text)
        }
        XCTAssertTrue(String(describing: outcome).contains("<redacted>"))
    }

    func testAReturnNamingAnotherRequestIsRefused() async throws {
        let node = serve(result: ["requestId": "r1", "kind": "createOrg", "status": "pending", "decidedAt": .null])
        let cloud = client()
        let started = try await cloud.requestConsent(.createOrg(name: "Acme", returnTo: Self.returnTo))
        let forged = try XCTUnwrap(URL(string: "\(Self.returnTo)&request_id=r2&result=approved"))
        do {
            _ = try await cloud.confirmConsentReturn(started, returned: forged)
            XCTFail("expected CONSENT_REQUEST_MISMATCH")
        } catch let error as CalimeroError {
            XCTAssertEqual(error.code, "CONSENT_REQUEST_MISMATCH")
        }
        XCTAssertFalse(node.requests.contains { $0.path.hasPrefix("/consent/r2") }, "r2's result is never read")
    }

    func testAReturnThatLeftThisRequestPendingIsRefused() async throws {
        serve(result: ["requestId": "r1", "kind": "createOrg", "status": "pending", "decidedAt": .null])
        let cloud = client()
        let started = try await cloud.requestConsent(.createOrg(name: "Acme", returnTo: Self.returnTo))
        let returned = try XCTUnwrap(URL(string: "\(Self.returnTo)&request_id=r1&result=approved"))
        do {
            _ = try await cloud.confirmConsentReturn(started, returned: returned)
            XCTFail("expected CONSENT_NOT_DECIDED")
        } catch let error as CalimeroError {
            XCTAssertEqual(error.code, "CONSENT_NOT_DECIDED")
        }
    }

    func testAReturnAfterThisRequestWasReplacedIsRefused() async throws {
        // One undecided request per account and node: a newer one replaced r1,
        // whose result is now 404 NOT_FOUND.
        let node = FakeCloudNode { request in
            switch (request.method, request.path) {
            case ("POST", "/consent/requests"):
                return .json([
                    "requestId": "r1", "url": "https://node.test/consent/r1", "expiresAt": 1_900_000_000,
                    "code": .string(confirmationCode("r1")),
                ])
            default: return .error(404, "NOT_FOUND")
            }
        }
        node.install()
        let cloud = client()
        let started = try await cloud.requestConsent(.createOrg(name: "Acme", returnTo: Self.returnTo))
        let returned = try XCTUnwrap(URL(string: "\(Self.returnTo)&request_id=r1&result=approved"))
        do {
            _ = try await cloud.confirmConsentReturn(started, returned: returned)
            XCTFail("expected CONSENT_REPLACED")
        } catch let error as CalimeroError {
            XCTAssertEqual(error.code, "CONSENT_REPLACED")
            XCTAssertEqual(error.details["requestId"], "r1")
        }
        // Outside a return, a 404 is the node's own refusal.
        do {
            _ = try await cloud.consentResult("r1")
            XCTFail("expected NOT_FOUND")
        } catch let error as CalimeroError {
            XCTAssertEqual(error.code, "NOT_FOUND")
        }
    }

    func testTheNodeDecidesNotTheReturnLink() async throws {
        serve(result: ["requestId": "r1", "kind": "createOrg", "status": "declined", "decidedAt": 2])
        let returned = try XCTUnwrap(URL(string: "\(Self.returnTo)&request_id=r1&result=approved"))
        let result = try await client().confirmConsentReturn(requestId: "r1", returned: returned)
        XCTAssertEqual(result.status, .declined)
        XCTAssertNil(result.outcome)
        XCTAssertNil(result.orgId)
    }

    func testAnOutcomeThatDoesNotFitItsKindIsRefused() async throws {
        let answers: [JSONValue] = [
            ["requestId": "r1", "kind": "createInvite", "status": "approved", "decidedAt": 2],
            ["requestId": "r1", "kind": "createOrg", "status": "approved", "decidedAt": 2, "outcome": ["org": "o1"]],
            ["requestId": "r2", "kind": "upgrade", "status": "approved", "decidedAt": 2],
        ]
        for answer in answers {
            serve(result: answer)
            do {
                _ = try await client().consentResult("r1")
                XCTFail("expected \(answer) to be refused")
            } catch AccountError.protocolViolation {}
            MockURLProtocol.reset()
        }
    }

    func testTheOlderKindsHaveNoOutcome() async throws {
        serve(result: ["requestId": "r1", "kind": "upgrade", "status": "approved", "decidedAt": 2])
        let result = try await client().consentResult("r1")
        XCTAssertTrue(result.isApproved)
        XCTAssertNil(result.outcome)
    }

    func testRefusesBadRequestsBeforeSending() async throws {
        let node = serve(result: [:])
        let cloud = client()
        let bad: [ConsentRequest] = [
            .createOrg(name: "  ", returnTo: Self.returnTo), .createOrg(name: "Acme", returnTo: ""),
            .createInvite(org: "o1", role: .owner, returnTo: Self.returnTo),
            .createInvite(org: "", role: .member, returnTo: Self.returnTo),
            .createInvite(org: "o1", role: .member, uses: -1, returnTo: Self.returnTo),
            .acceptInvite(token: "", returnTo: Self.returnTo),
        ]
        for request in bad {
            do {
                _ = try await cloud.requestConsent(request)
                XCTFail("expected \(request) to be refused")
            } catch AccountError.invalidInput {}
        }
        XCTAssertTrue(node.requests.isEmpty)
    }
}
