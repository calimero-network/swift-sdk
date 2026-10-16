import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `admin-api/redeem-invitation.test.ts`.
final class RedeemInvitationTests: XCTestCase {
    private let ns = DelegatedFixture.rep("01")
    private var request: RedeemRequest {
        RedeemRequest(namespaceId: ns, invitation: RedeemInvitationTests.invitation, teamName: "Team")
    }

    static let invitation = SignedGroupOpenInvitation(
        invitation: GroupInvitationFromAdmin(
            inviterIdentity: Array(repeating: 1, count: 32), groupId: Array(repeating: 2, count: 32),
            expirationTimestamp: 0, secretSalt: Array(repeating: 3, count: 32), invitedRole: 1, admitters: []),
        inviterSignature: "sig")

    private func http(_ status: Int, _ message: String) -> Error {
        MeroError.http(
            HTTPError(
                status: status, statusText: "", url: "", headers: [:],
                bodyText: #"{"error":"\#(message)"}"#))
    }

    private func redeemer(
        join: Error? = nil, memberships: [String]? = [], joins: Counter = Counter()
    ) -> InviteRedeemer {
        InviteRedeemer(
            join: { _, _ in
                joins.increment()
                if let join { throw join }
            },
            memberships: {
                guard let memberships else { throw URLError(.timedOut) }
                return memberships
            })
    }

    func testReportsACleanJoin() async {
        let outcome = await redeemInvitation(request, redeemer: redeemer())
        XCTAssertEqual(outcome, .joined(namespaceId: ns, teamName: "Team"))
        XCTAssertTrue(outcome.isSettled)
        XCTAssertFalse(shouldRetain(outcome))
    }

    func testReportsAlreadyMemberWhenTheRequestFailedButTheNodeJoined() async {
        let outcome = await redeemInvitation(
            request, redeemer: redeemer(join: http(504, "timed out"), memberships: [ns]))
        XCTAssertEqual(outcome, .alreadyMember(namespaceId: ns, teamName: "Team"))
    }

    func testKeepsAResolvedJoinEvenWhenTheMembershipCheckThrows() async {
        let outcome = await redeemInvitation(request, redeemer: redeemer(memberships: nil))
        XCTAssertEqual(outcome, .joined(namespaceId: ns, teamName: "Team"))
    }

    func testTreatsAnUnreadableMembershipListAsUnknownNotAbsent() async {
        let outcome = await redeemInvitation(
            request, redeemer: redeemer(join: http(503, "no member online"), memberships: nil))
        XCTAssertEqual(
            outcome, .failed(namespaceId: ns, message: "no member online", reason: .noOneOnline, retryable: true))
        XCTAssertTrue(outcome.shouldRetain)
    }

    func testNeverSendsASecondJoinToSettleAnAmbiguousOne() async {
        let joins = Counter()
        _ = await redeemInvitation(request, redeemer: redeemer(join: http(504, "x"), joins: joins))
        XCTAssertEqual(joins.count, 1)
    }

    func testCarriesTheNodesOwnWords() async {
        let outcome = await redeemInvitation(
            request, redeemer: redeemer(join: http(503, "could not reach any member of this namespace")))
        guard case .failed(_, let message, _, _) = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "could not reach any member of this namespace")
    }

    func testAFinalStatusDropsTheInvitation() async {
        let cases = [
            RedeemStatusCase(status: 400, message: "a malformed invitation", reason: .invalid),
            RedeemStatusCase(status: 403, message: "node is not a member of group g", reason: .refused),
            RedeemStatusCase(
                status: 409, message: "invitation for group g expired at 1759000000 (unix seconds)", reason: .expired),
            RedeemStatusCase(status: 409, message: "member was removed from group g", reason: .refused),
            RedeemStatusCase(status: 410, message: "gone", reason: .expired),
        ]
        for item in cases {
            let outcome = await redeemInvitation(request, redeemer: redeemer(join: http(item.status, item.message)))
            XCTAssertEqual(
                outcome, .failed(namespaceId: ns, message: item.message, reason: item.reason, retryable: false),
                "\(item.status)")
            XCTAssertFalse(shouldRetain(outcome))
        }
    }

    func testAPassingFailureKeepsTheInvitation() async {
        let cases: [(Error, InviteFailureReason)] = [
            (http(401, "no"), .signedOut),
            (http(503, "no"), .noOneOnline),
            (http(504, "no"), .noOneOnline),
            (MeroError.network("offline"), .nodeUnreachable),
            (http(404, "no"), .unknown),
            (http(413, "no"), .unknown),
            (http(429, "no"), .unknown),
            (http(500, "no"), .unknown),
            (URLError(.cannotConnectToHost), .nodeUnreachable),
        ]
        for (error, reason) in cases {
            let outcome = await redeemInvitation(request, redeemer: redeemer(join: error))
            guard case .failed(_, _, let got, let retryable) = outcome else { return XCTFail("expected a failure") }
            XCTAssertEqual(got, reason, "\(error)")
            XCTAssertTrue(retryable)
            XCTAssertTrue(shouldRetain(outcome))
        }
    }

    func testStillRecognisesAnOldNodesRefusalByItsMessage() async {
        for message in [
            "invitation expired",
            "invitation for group ContextGroupId(Identity([12, 34])) expired at 1759000000 (unix seconds)",
            "invitation for group ContextGroupId(Identity([12, 34])) is invalid: it carries no application_id",
        ] {
            let outcome = await redeemInvitation(request, redeemer: redeemer(join: http(500, message)))
            guard case .failed(_, _, _, let retryable) = outcome else { return XCTFail("expected a failure") }
            XCTAssertFalse(retryable, message)
        }
    }

    func testAdminRedeemsThroughJoinNamespaceAndSettlesByTheListing() async throws {
        let rig = CloudRig()
        rig.install()
        defer { MockURLProtocol.reset() }
        rig.on("POST", "/admin-api/namespaces/\(ns)/join", status: 504, json: #"{"error":"gateway timeout"}"#)
        rig.on(
            "GET", "/admin-api/namespaces",
            json: #"{"data":[{"namespaceId":"\#(ns)","appKey":"k","targetApplicationId":"a","createdAt":0,"#
                + #""memberCount":1,"contextCount":0,"subgroupCount":0}]}"#)
        let http = URLSessionHttpClient(
            baseURL: URL(string: "https://node.test")!, session: MockURLProtocol.makeSession())
        let admin = AdminApi(http: http)
        let outcome = await admin.redeemInvitation(
            ns, invitation: RedeemInvitationTests.invitation, groupName: "general", teamName: "Team")
        XCTAssertEqual(outcome, .alreadyMember(namespaceId: ns, teamName: "Team"))
        let join = try XCTUnwrap(rig.requests("POST", "/admin-api/namespaces/\(ns)/join").first?.json)
        XCTAssertEqual(join["groupName"], "general")
        XCTAssertEqual(rig.requests("POST", "/admin-api/namespaces/\(ns)/join").count, 1)
    }
}

/// One status a join is refused with, and what it should read as.
struct RedeemStatusCase {
    let status: Int
    let message: String
    let reason: InviteFailureReason
}
