import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// `client.consent.request / result / resume / wait` against a
/// ``FakeCloudNode`` (the real sealed channel), every kind core's consent
/// page decides, with the outcome typed by kind.
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

    private static func started(_ id: String) -> FakeCloudAnswer {
        .json([
            "requestId": .string(id), "url": .string("https://node.test/consent/\(id)"), "expiresAt": 1_900_000_000,
            "code": .string(confirmationCode(id)),
        ])
    }

    /// A node that starts request `r1` and answers `result` for it.
    private func serve(result: JSONValue) -> FakeCloudNode {
        let node = FakeCloudNode { request in
            switch (request.method, request.path) {
            case ("POST", "/consent/requests"): return Self.started("r1")
            case ("GET", "/consent/r1/result"): return .json(result)
            default: return .error(404, "NOT_FOUND")
            }
        }
        node.install()
        return node
    }

    func testEveryKindsBodyIsCores() {
        let returnTo = "https://chat.example/consent"
        XCTAssertEqual(
            ConsentAsk.createOrg(name: "Acme").body(returnTo: returnTo),
            ["kind": "createOrg", "subject": ["name": "Acme"], "returnTo": .string(returnTo)])
        XCTAssertEqual(
            ConsentAsk.createInvite(org: "o1", role: .member).body(returnTo: returnTo),
            ["kind": "createInvite", "subject": ["org": "o1", "role": "member"], "returnTo": .string(returnTo)])
        XCTAssertEqual(
            ConsentAsk.createInvite(org: "o1", role: .admin, teams: ["t1"], ttlSecs: 3600, uses: 5, allApps: true)
                .body(returnTo: returnTo),
            [
                "kind": "createInvite",
                "subject": [
                    "org": "o1", "role": "admin", "teams": ["t1"], "ttlSecs": 3600, "uses": 5, "allApps": true,
                ],
                "returnTo": .string(returnTo),
            ])
        XCTAssertEqual(
            ConsentAsk.acceptInvite(token: "inv_secret").body(returnTo: returnTo),
            ["kind": "acceptInvite", "subject": ["token": "inv_secret"], "returnTo": .string(returnTo)])
        XCTAssertEqual(
            ConsentAsk.release(scope: .org("o1"), version: "2.3.110").body(returnTo: returnTo),
            [
                "kind": "release", "scope": ["org": "o1"], "subject": ["version": "2.3.110"],
                "returnTo": .string(returnTo),
            ])
        XCTAssertEqual(
            ConsentAsk.upgrade(app: "a1", toVersion: "1.1.0").body(returnTo: returnTo),
            ["kind": "upgrade", "subject": ["app": "a1", "toVersion": "1.1.0"], "returnTo": .string(returnTo)])
        XCTAssertEqual(
            ConsentAsk.outbound(scope: .account, prefixes: ["https://api.example/"]).body(returnTo: returnTo),
            [
                "kind": "outbound", "scope": "account", "subject": ["prefixes": ["https://api.example/"]],
                "returnTo": .string(returnTo),
            ])
        // The same body the 0.x `ConsentRequest` sends for the kinds both know.
        XCTAssertEqual(
            ConsentAsk.release(scope: .account, version: "2.3.110", withdraw: true).body(returnTo: returnTo),
            ConsentRequest.release(scope: .account, version: "2.3.110", withdraw: true, returnTo: returnTo).json)
    }

    func testCreatesAnOrganizationThroughTheConsentPage() async throws {
        let node = serve(result: [
            "requestId": "r1", "kind": "createOrg", "status": "approved", "decidedAt": 2, "outcome": ["orgId": "o9"],
        ])
        let cloud = client()
        let started = try await cloud.consent.request(.createOrg(name: "Acme"), returnTo: "https://chat.example/c")
        XCTAssertEqual(started.requestId, "r1")
        XCTAssertEqual(started.code, confirmationCode("r1"))
        XCTAssertEqual(started.url, "https://node.test/consent/r1")
        let body = try XCTUnwrap(node.requests.first { $0.path == "/consent/requests" }?.json)
        XCTAssertEqual(body["kind"], "createOrg")
        XCTAssertEqual(body["returnTo"], "https://chat.example/c")

        let decision = try await cloud.consent.wait(requestId: started.requestId)
        XCTAssertTrue(decision.isApproved)
        XCTAssertEqual(decision.kind, .createOrg)
        XCTAssertEqual(decision.outcome, .orgCreated(orgId: "o9"))
        XCTAssertEqual(decision.orgId, "o9")
        XCTAssertNil(decision.inviteToken)
        XCTAssertEqual(decision.decidedAt, 2)
        XCTAssertEqual(decision.result.kind, "createOrg")
    }

    func testAnInviteTokenIsTypedAndNeverDescribed() async throws {
        _ = serve(result: [
            "requestId": "r1", "kind": "createInvite", "status": "approved", "decidedAt": 2,
            "outcome": ["token": "inv_secret_123"],
        ])
        let cloud = client()
        let started = try await cloud.consent.request(
            .createInvite(org: "o1", role: .member, uses: 1), returnTo: "https://chat.example/c")
        let decision = try await cloud.consent.wait(requestId: started.requestId)
        XCTAssertEqual(decision.inviteToken, "inv_secret_123")

        // Nothing a log line could take from these shows the token.
        let ask = ConsentAsk.acceptInvite(token: "inv_secret_123")
        let outcome = try XCTUnwrap(decision.outcome)
        var dumped = ""
        dump(decision, to: &dumped)
        dump(ask, to: &dumped)
        dump(outcome, to: &dumped)
        let texts = [
            String(describing: decision), String(reflecting: decision), "\(decision)", String(describing: ask),
            String(reflecting: ask), String(describing: outcome), String(reflecting: outcome),
            String(describing: Optional(outcome)), String(describing: [decision]), dumped,
        ]
        for text in texts {
            XCTAssertFalse(text.contains("inv_secret_123"), text)
        }
        XCTAssertTrue(String(describing: outcome).contains("<redacted>"))
    }

    func testAcceptsAnInviteAndResumesFromTheUniversalLink() async throws {
        let node = serve(result: [
            "requestId": "r1", "kind": "acceptInvite", "status": "approved", "decidedAt": 2, "outcome": ["org": "o1"],
        ])
        let cloud = client()
        _ = try await cloud.consent.request(.acceptInvite(token: "inv_x"), returnTo: "https://chat.example/c")
        let body = try XCTUnwrap(node.requests.first { $0.path == "/consent/requests" }?.json)
        XCTAssertEqual(body["subject"]?["token"], "inv_x")

        let link = try XCTUnwrap(URL(string: "https://chat.example/c?request_id=r1&result=approved"))
        let decision = try await cloud.consent.resume(url: link)
        XCTAssertEqual(decision?.joinedOrg, "o1")
        XCTAssertEqual(decision?.outcome, .inviteAccepted(org: "o1"))
        XCTAssertEqual(node.requests.last?.path, "/consent/r1/result", "the node's answer, not the link's")

        let elsewhere = try XCTUnwrap(URL(string: "https://chat.example/rooms/1"))
        let none = try await cloud.consent.resume(url: elsewhere)
        XCTAssertNil(none)
    }

    func testTheNodeDecidesNotTheReturnLink() async throws {
        _ = serve(result: ["requestId": "r1", "kind": "createOrg", "status": "declined", "decidedAt": 2])
        let link = try XCTUnwrap(URL(string: "https://chat.example/c?request_id=r1&result=approved"))
        let decision = try await client().consent.resume(url: link)
        XCTAssertEqual(decision?.status, .declined)
        XCTAssertNil(decision?.outcome)
        XCTAssertNil(decision?.orgId)
    }

    func testWaitPollsUntilDecided() async throws {
        let polls = Box(0)
        FakeCloudNode { request in
            guard request.path == "/consent/r1/result" else { return .error(404, "NOT_FOUND") }
            polls.update { $0 += 1 }
            if polls.get < 3 {
                return .json(["requestId": "r1", "kind": "upgrade", "status": "pending", "decidedAt": .null])
            }
            return .json(["requestId": "r1", "kind": "upgrade", "status": "approved", "decidedAt": 5])
        }.install()
        let decision = try await client().consent.wait(requestId: "r1", interval: 0)
        XCTAssertEqual(polls.get, 3)
        XCTAssertTrue(decision.isApproved)
        XCTAssertNil(decision.outcome, "an upgrade makes nothing")
    }

    func testWaitAnswersPendingWhenItTimesOut() async throws {
        _ = serve(result: ["requestId": "r1", "kind": "createOrg", "status": "pending", "decidedAt": .null])
        let decision = try await client().consent.wait(requestId: "r1", timeout: 0)
        XCTAssertEqual(decision.status, .pending)
        XCTAssertFalse(decision.isDecided)
        XCTAssertNil(decision.decidedAt)
    }

    func testAnUnknownKindStillDecodes() throws {
        let decision = try ConsentDecision(json: [
            "requestId": "r1", "kind": "somethingNew", "status": "approved", "decidedAt": 2, "outcome": ["x": "y"],
        ])
        XCTAssertEqual(decision.kind.rawValue, "somethingNew")
        XCTAssertNil(decision.outcome)
    }

    func testAnApprovedOutcomeKindWithoutItsOutcomeIsRefused() {
        let answer: JSONValue = ["requestId": "r1", "kind": "createInvite", "status": "approved", "decidedAt": 2]
        XCTAssertThrowsError(try ConsentDecision(json: answer)) { error in
            guard case AccountError.protocolViolation = error else { return XCTFail("\(error)") }
        }
    }

    func testRefusesBadAsksBeforeSending() async throws {
        let node = serve(result: [:])
        let cloud = client()
        let bad: [ConsentAsk] = [
            .createOrg(name: "  "), .createInvite(org: "o1", role: .owner), .createInvite(org: "", role: .member),
            .createInvite(org: "o1", role: .member, uses: -1), .acceptInvite(token: ""),
        ]
        for ask in bad {
            do {
                _ = try await cloud.consent.request(ask, returnTo: "https://chat.example/c")
                XCTFail("expected \(ask) to be refused")
            } catch AccountError.invalidInput {}
        }
        do {
            _ = try await cloud.consent.request(.createOrg(name: "Acme"), returnTo: "")
            XCTFail("expected an empty returnTo to be refused")
        } catch AccountError.invalidInput {}
        XCTAssertTrue(node.requests.isEmpty)
    }

    func testAMismatchedCodeIsRefused() async throws {
        FakeCloudNode { _ in
            .json(["requestId": "r1", "url": "https://node.test/consent/r1", "expiresAt": 1, "code": "AAA-AAA"])
        }.install()
        do {
            _ = try await client().consent.request(.createOrg(name: "Acme"), returnTo: "https://chat.example/c")
            XCTFail("expected CONSENT_CODE_MISMATCH")
        } catch let error as CalimeroError {
            XCTAssertEqual(error.code, "CONSENT_CODE_MISMATCH")
        }
    }

    func testANodeRefusalIsTyped() async throws {
        FakeCloudNode { _ in .error(404, "NOT_FOUND") }.install()
        do {
            _ = try await client().consent.result(requestId: "r2")
            XCTFail("expected NOT_FOUND")
        } catch let error as CalimeroError {
            XCTAssertEqual(error.code, "NOT_FOUND")
        }
    }
}
