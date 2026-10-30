import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A thread-safe box for what a fake node saw.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    var get: T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout T) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

/// Port of mero-js `cloud-v2/client.test.ts`'s journeys, against a
/// ``FakeCloudNode`` that runs the real sealed channel (Noise NK, sealed
/// frames) and mock attestation.
final class CalimeroClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client(
        _ base: String = "https://node.test", nodes: [String] = [], allowMock: Bool = true
    ) -> CalimeroClient {
        CalimeroClient(
            CalimeroClientOptions(
                baseUrl: base, nodes: nodes, policy: CloudPolicy(allowMock: allowMock),
                session: MockURLProtocol.makeSession(), retry: CloudRetryOptions(retries: 3)),
            sleep: { _ in })
    }

    private static let session: JSONValue = [
        "accountId": "acc_1", "sessionToken": "v2.one", "expiresAt": 1_900_000_000, "refreshToken": "rt_one",
    ]

    private static func passkeyCeremonies(_ request: FakeCloudRequest) -> FakeCloudAnswer? {
        switch request.path {
        case "/auth/passkey/register/begin":
            return .json([
                "challengeId": "ch1",
                "options": [
                    "challenge": .string(b64url(Data(repeating: 7, count: 32))),
                    "rp": ["id": "localhost", "name": "x"],
                    "user": ["id": .string(b64url(Data([1, 2, 3]))), "name": "ada", "displayName": "ada"],
                ],
            ])
        case "/auth/passkey/login/begin":
            return .json([
                "challengeId": "ch2",
                "options": ["challenge": .string(b64url(Data(repeating: 9, count: 32))), "rpId": "localhost"],
            ])
        case "/auth/passkey/register/finish", "/auth/passkey/login/finish": return .json(session)
        default: return nil
        }
    }

    func testSignsUpWithAPasskeyOverTheSealedChannelAndSendsTheSessionAfter() async throws {
        let node = FakeCloudNode { request in
            Self.passkeyCeremonies(request) ?? .json(["accountId": "acc_1", "orgs": []])
        }
        node.install()
        let cloud = client()
        let session = try await cloud.signUp(SoftPasskey(), name: "ada")
        XCTAssertEqual(session.accountId, "acc_1")
        let me = try await cloud.me()
        XCTAssertEqual(me.accountId, "acc_1")

        XCTAssertEqual(node.attests, 1)
        XCTAssertEqual(node.handshakes, 1)
        XCTAssertEqual(
            node.requests.map(\.path), ["/auth/passkey/register/begin", "/auth/passkey/register/finish", "/auth/me"])
        let finish = try XCTUnwrap(node.requests[1].json)
        XCTAssertEqual(finish["challengeId"], "ch1")
        XCTAssertNotNil(finish["registration"]?["attestationObject"]?.stringValue)
        XCTAssertNil(node.requests[0].bearer)
        XCTAssertEqual(node.requests[2].bearer, "v2.one")
    }

    func testSignsInWithTheAssertionOverTheNodesChallenge() async throws {
        let node = FakeCloudNode { Self.passkeyCeremonies($0) ?? .error(404, "NOT_FOUND") }
        node.install()
        let passkey = SoftPasskey()
        try await client().signIn(passkey)
        let assertion = try XCTUnwrap(node.requests[1].json?["assertion"])
        XCTAssertEqual(assertion["credentialId"]?.stringValue, passkey.credentialId)
        let clientData = try JSONDecoder().decode(
            JSONValue.self, from: try fromB64url(assertion["clientDataJson"]?.stringValue ?? ""))
        XCTAssertEqual(clientData["challenge"]?.stringValue, b64url(Data(repeating: 9, count: 32)))
        XCTAssertEqual(clientData["type"], "webauthn.get")
    }

    func testRefusesAMockQuoteUnlessTheCallerAllowsMock() async throws {
        let node = FakeCloudNode { _ in .json([:]) }
        node.install()
        do {
            _ = try await client(allowMock: false).me()
            XCTFail("a mock quote must be refused")
        } catch let error as TeeTrustError {
            XCTAssertTrue(error.message.contains("mock quote refused"), error.message)
        }
        XCTAssertEqual(node.handshakes, 0, "nothing is sent to a node that did not attest")
    }

    func testCallsAndViewsAnAppAndRetriesA503WithTheSameIdempotencyKey() async throws {
        let attempts = Counter()
        let node = FakeCloudNode { request in
            if request.path == "/apps/a1/intents" {
                attempts.increment()
                if attempts.count < 3 { return .error(503, "TIMEOUT") }
                return .json(["index": 7, "result": ["ok": true], "events": [["kind": "Set", "data": "a"]]])
            }
            return .json(["index": 7, "result": "1"])
        }
        node.install()
        let cloud = client()
        let call = try await cloud.call("a1", "set", ["key": "a"])
        XCTAssertEqual(call.index, 7)
        XCTAssertEqual(call.result?["ok"], true)
        XCTAssertEqual(call.events.first?.kind, "Set")
        let keys = node.requests.filter { $0.path == "/apps/a1/intents" }.compactMap {
            $0.json?["idempotencyKey"]?.stringValue
        }
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1, "every retry carries the same key")
        XCTAssertTrue(keys[0].hasPrefix("node:c-"))

        let view = try await cloud.view("a1", "get", ["key": "a"])
        XCTAssertEqual(view.result, "1")
        let body = try XCTUnwrap(node.requests.last?.json)
        XCTAssertEqual(body["consistency"], "strong")
        XCTAssertEqual(body["method"], "get")
    }

    func testGivesUpOnA503AfterItsRetriesAsUnavailable() async throws {
        let node = FakeCloudNode { _ in .error(503, "MIGRATING", message: "moving") }
        node.install()
        do {
            _ = try await client().call("a1", "set")
            XCTFail("expected unavailable")
        } catch let error as UnavailableError {
            XCTAssertEqual(error.reason, "migrating")
            XCTAssertEqual(error.committed, .no)
        }
        XCTAssertEqual(node.requests.count, 4, "the first attempt and 3 retries")
    }

    func testMapsTheNodesRefusalsToTypedErrors() {
        func error(_ status: Int, _ code: String, _ details: JSONValue? = nil) -> CalimeroError {
            var body: [String: JSONValue] = ["error": .string(code), "message": "m"]
            if let details { body["details"] = details }
            return errorFrom(status: status, body: .object(body))
        }
        XCTAssertTrue(error(401, "UNAUTHENTICATED") is LoginRequired)
        XCTAssertTrue(error(421, "WRONG_NODE") is WrongNode)
        XCTAssertEqual((error(421, "NOT_LEADER", ["leaderUrl": "https://n2"]) as? NotLeader)?.leaderUrl, "https://n2")
        XCTAssertTrue(error(404, "NOT_FOUND") is NotFound)
        XCTAssertTrue(error(412, "CONFIRM_REQUIRED") is ConfirmRequired)
        XCTAssertTrue(error(413, "ARGS_TOO_LARGE") is ArgsTooLarge)
        XCTAssertTrue(error(409, "IDEMPOTENCY_MISMATCH") is IdempotencyMismatch)
        XCTAssertTrue(error(409, "CONSENT_STALE") is ConsentStale)
        XCTAssertEqual(
            (error(409, "RELEASE_DEADLINE", ["release": "2.3.110"]) as? ReleaseDeadlineError)?.release, "2.3.110")
        XCTAssertEqual((error(422, "TRAP", ["kind": "OutOfFuel"]) as? TrapError)?.kind, "OutOfFuel")
        let app =
            error(422, "APP_ERROR", ["index": 1, "error": ["code": "Taken", "fields": ["name": "x"]]]) as? AppError
        XCTAssertEqual(app?.appCode, "Taken")
        XCTAssertEqual(app?.fields["name"], "x")
        let flat = error(422, "APP_ERROR", ["code": "Forbidden", "fields": ["0": "positional"]]) as? AppError
        XCTAssertEqual(flat?.appCode, "Forbidden")
        let unavailable = errorFrom(status: 503, body: ["error": "UNAVAILABLE"], retryAfter: "2") as? UnavailableError
        XCTAssertEqual(unavailable?.committed, .unknown)
        XCTAssertEqual(unavailable?.retryAfter, 2)
        let other = error(409, "CONFLICT")
        XCTAssertFalse(other is IdempotencyMismatch)
        XCTAssertEqual(other.code, "CONFLICT")
    }

    func testRefreshesOnceForConcurrentRequestsAfterA401AndRepeatsThem() async throws {
        let refreshes = Counter()
        let node = FakeCloudNode { request in
            if request.path == "/auth/refresh" {
                refreshes.increment()
                return .json([
                    "accountId": "acc_1", "sessionToken": "v2.two", "expiresAt": 1_900_000_000,
                    "refreshToken": "rt_two",
                ])
            }
            if request.bearer == "v2.one" { return .error(401, "UNAUTHENTICATED") }
            return .json(["index": 1, "result": .string(request.bearer ?? "")])
        }
        node.install()
        let cloud = client()
        let seen = Box<[CalimeroSession?]>([])
        await cloud.onSessionChange { session in seen.update { $0.append(session) } }
        await cloud.useSession(
            CalimeroSession(accountId: "acc_1", sessionToken: "v2.one", expiresAt: 0, refreshToken: "rt_one"))
        async let first = cloud.view("a1", "get")
        async let second = cloud.view("a1", "get")
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.result), ["v2.two", "v2.two"])
        XCTAssertEqual(refreshes.count, 1, "a refresh token is used once")
        XCTAssertEqual(node.requests.first { $0.path == "/auth/refresh" }?.json?["refreshToken"], "rt_one")
        let current = await cloud.session
        XCTAssertEqual(current?.refreshToken, "rt_two")
        XCTAssertEqual(seen.get.last??.refreshToken, "rt_two")
    }

    func testARefusedRefreshSurfacesAsLoginRequired() async throws {
        let node = FakeCloudNode { _ in .error(401, "UNAUTHENTICATED", message: "expired") }
        node.install()
        let cloud = client()
        await cloud.useSession(
            CalimeroSession(accountId: "a", sessionToken: "v2.x", expiresAt: 0, refreshToken: "rt_x"))
        do {
            _ = try await cloud.me()
            XCTFail("expected LoginRequired")
        } catch is LoginRequired {}
        XCTAssertEqual(node.requests.map(\.path), ["/auth/me", "/auth/refresh"])
    }

    func testMovesToTheNextNodeOnWrongNodeAndRepeatsTheRequestThere() async throws {
        let first = FakeCloudNode(baseURL: "https://n1.test") { _ in .error(421, "WRONG_NODE") }
        let second = FakeCloudNode(baseURL: "https://n2.test") { _ in .json(["index": 2, "result": "there"]) }
        FakeCloudNode.install([first, second])
        let cloud = client("https://n1.test", nodes: ["https://n2.test/"])
        let answer = try await cloud.view("a1", "get")
        XCTAssertEqual(answer.result, "there")
        let now = await cloud.nodeUrl
        XCTAssertEqual(now, "https://n2.test")
        XCTAssertEqual(second.attests, 1, "the next node is attested before anything is sent to it")
    }

    func testAWrongNodeWithNoOtherNodeReachesTheCaller() async throws {
        FakeCloudNode { _ in .error(421, "WRONG_NODE") }.install()
        do {
            _ = try await client().me()
            XCTFail("expected WrongNode")
        } catch is WrongNode {}
    }

    func testFollowsNotLeaderToALeaderItKnows() async throws {
        let follower = FakeCloudNode(baseURL: "https://n1.test") { _ in
            .error(421, "NOT_LEADER", details: ["leader": 2, "leaderUrl": "https://n2.test"])
        }
        let leader = FakeCloudNode(baseURL: "https://n2.test") { _ in .json(["status": "ok"]) }
        FakeCloudNode.install([follower, leader])
        let answer = try await client("https://n1.test", nodes: ["https://n2.test"]).post("ops/nodes", [:])
        XCTAssertEqual(answer["status"], "ok")
        XCTAssertEqual(leader.requests.count, 1)
    }

    func testAnswersAConfirmRequiredWithThePasskeyAndSendsTheCallOnce() async throws {
        let node = FakeCloudNode { request in
            if request.json?["confirm"] == nil {
                return .error(
                    412, "CONFIRM_REQUIRED",
                    details: [
                        "challengeId": "c9", "challenge": .string(b64url(Data(repeating: 3, count: 32))),
                        "rpId": "localhost",
                    ])
            }
            return .json(["index": 4, "result": "paid"])
        }
        node.install()
        let answer = try await client().callConfirmed("a1", "pay", ["amount": 5], passkey: SoftPasskey())
        XCTAssertEqual(answer.result, "paid")
        let confirmed = try XCTUnwrap(node.requests.last?.json)
        XCTAssertEqual(confirmed["confirm"]?["challengeId"], "c9")
        XCTAssertEqual(confirmed["idempotencyKey"], node.requests.first?.json?["idempotencyKey"])
    }

    func testADeclinedConfirmationIsConfirmCancelled() async throws {
        struct Declining: PasskeyProvider {
            func create(options: JSONValue) async throws -> RegistrationJSON { throw PasskeyCancelled() }
            func get(challenge: Data, rpId: String, allowCredentials: [String]?) async throws -> AssertionJSON {
                throw PasskeyCancelled()
            }
        }
        FakeCloudNode { _ in
            .error(412, "CONFIRM_REQUIRED", details: ["challengeId": "c", "challenge": "AAAA", "rpId": "localhost"])
        }.install()
        do {
            try await client().deleteOrg("o1", passkey: Declining())
            XCTFail("expected ConfirmCancelled")
        } catch is ConfirmCancelled {}
    }

    func testStreamsAnAppsEventsFromTheSealedEventStream() async throws {
        let node = FakeCloudNode { _ in
            .events(
                [
                    FakeCloudEvent(id: "3:0", kind: "Posted", data: ["id": "m1"]),
                    FakeCloudEvent(id: "3:1", kind: "Posted", data: ["id": "m2"]),
                ], holdOpen: true)
        }
        node.install()
        var seen: [CloudEvent] = []
        for try await event in client().events("a1", from: 3) {
            seen.append(event)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen.map(\.id), ["3:0", "3:1"])
        XCTAssertEqual(seen.map(\.kind), ["Posted", "Posted"])
        XCTAssertEqual(seen.last?.data["id"], "m2")
        XCTAssertEqual(node.requests.first?.path, "/apps/a1/events?from=3")
    }

    func testOrgsTeamsInvitesAndConsent() async throws {
        let node = FakeCloudNode { request in
            switch (request.method, request.path) {
            case ("POST", "/orgs"): return .json(["orgId": "o1"])
            case ("POST", "/orgs/o1/teams"): return .json(["teamId": "t1"])
            case ("POST", "/orgs/o1/invites"): return .json(["token": "inv_x"])
            case ("POST", "/invites/inv_x/redeem"): return .json(["orgId": "o1"])
            case ("POST", "/consent/requests"):
                return .json(["requestId": "r1", "url": "https://node.test/consent/r1", "expiresAt": 1])
            case ("GET", "/consent/r1/result"):
                return .json(["requestId": "r1", "kind": "upgrade", "status": "approved", "decidedAt": 2])
            case ("POST", "/apps"): return .json(["appId": "a1", "contextId": "c"])
            default: return .json([:])
            }
        }
        node.install()
        let cloud = client()
        let org = try await cloud.createOrg("Acme")
        XCTAssertEqual(org, "o1")
        let team = try await cloud.createTeam("o1", name: "General", join: .everyone)
        XCTAssertEqual(team, "t1")
        let app = try await cloud.createApp(
            "chat", bundle: .package("com.calimero.chat"), org: "o1", access: .team("t1"), initArgs: [:])
        XCTAssertEqual(app, "a1")
        let created = try XCTUnwrap(node.requests.last?.json)
        XCTAssertEqual(created["package"], "com.calimero.chat")
        XCTAssertEqual(created["access"], ["kind": "team", "team": "t1"])
        let token = try await cloud.invite("o1")
        XCTAssertEqual(token, "inv_x")
        _ = try await cloud.redeemInvite("inv_x")
        let started = try await cloud.openConsentPage(
            upgradeConsent(app: "a1", toVersion: "1.1.0", returnTo: "chat://consent")
        ) { url in
            XCTAssertEqual(url.absoluteString, "https://node.test/consent/r1")
        }
        let consentBody = try XCTUnwrap(node.requests.first { $0.path == "/consent/requests" }?.json)
        XCTAssertEqual(consentBody["kind"], "upgrade")
        XCTAssertEqual(consentBody["subject"]?["toVersion"], "1.1.0")
        let result = try await cloud.waitForConsent(started.requestId)
        XCTAssertEqual(result.status, .approved)
        let back = consentReturn(URL(string: "chat://consent?request_id=r1&result=approved")!)
        XCTAssertEqual(back?.requestId, "r1")
        XCTAssertEqual(back?.approved, true)
    }

    func testTheContractKeepsEveryNumberExactlyAsWritten() async throws {
        let exact = #"{"at":1761650000123456789,"max":18446744073709551615}"#
        let node = FakeCloudNode { request in
            let args = String(decoding: request.body, as: UTF8.self)
            let start = args.range(of: #""args":"#)!.upperBound
            let end =
                args.range(of: #","idempotencyKey""#)?.lowerBound ?? args.range(of: #","consistency""#)!.lowerBound
            return FakeCloudAnswer(
                status: 200, headers: [("content-type", "application/json")],
                chunks: [Data(#"{"index":1,"result":\#(args[start..<end]),"events":[]}"#.utf8)])
        }
        node.install()
        let bound = CloudContextContract(client: client()).bound(to: "a1")
        let sent = #"{ "max": 18446744073709551615, "at": 1761650000123456789 }"#
        let called = try await bound.execute(method: "stamp", argsJSON: Data(sent.utf8))
        XCTAssertEqual(String(decoding: called, as: UTF8.self), exact)
        let viewed = try await bound.query(method: "stamps", argsJSON: Data(sent.utf8))
        XCTAssertEqual(String(decoding: viewed, as: UTF8.self), exact)
    }

    func testCanonicalSpellingMatchesCanonicalJSONBesideTheIntegers() throws {
        let input = #" { "b" : 1, "a" : [1.50, -0, 1e3, "xé\n\/", true, null, {}] } "#
        let literal = String(decoding: try LiteralJSON.canonical(Data(input.utf8)), as: UTF8.self)
        XCTAssertEqual(literal, #"{"a":[1.5,0,1000,"xé\n/",true,null,{}],"b":1}"#)
    }
}
