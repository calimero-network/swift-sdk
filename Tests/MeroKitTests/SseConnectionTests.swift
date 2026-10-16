import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The long-lived SSE connection (port of mero-js `sse.test.ts`): live
/// subscribe/unsubscribe, re-subscribe after a reconnect, the connect
/// announcement, backoff, terminal failures, presence seed.
final class SseConnectionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func params(_ body: [String: Any]) -> [String: Any] {
        body["params"] as? [String: Any] ?? [:]
    }

    // MARK: - Subscriptions on a live connection

    func testSubscribeAndUnsubscribeOnTheLiveSession() async throws {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))])
        node.install()
        let sse = SseConnection.testing()
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.remember(contextIds: ["c1"], groupIds: [])
        sse.connect()
        defer { sse.close() }
        let connected = await eventually { log.values == [.connect("s1")] }
        XCTAssertTrue(connected, "\(log.values)")
        XCTAssertEqual(node.subscriptions.count, 1, "the remembered id is subscribed on connect")
        XCTAssertEqual(sse.sessionId, "s1")

        try await sse.subscribe(contextIds: ["c1", "c2", "c2"], groupIds: ["g1"])
        let added = try XCTUnwrap(node.subscriptions.last)
        XCTAssertEqual(added["id"] as? String, "s1")
        XCTAssertEqual(added["method"] as? String, "subscribe")
        XCTAssertEqual(params(added)["contextIds"] as? [String], ["c2"], "only ids not held yet, once each")
        XCTAssertEqual(params(added)["groupIds"] as? [String], ["g1"])
        XCTAssertTrue(sse.isSubscribed("c2"))
        XCTAssertTrue(sse.isSubscribed(groupId: "g1"))

        try await sse.subscribe(contextIds: ["c1"])
        XCTAssertEqual(node.subscriptions.count, 2, "nothing new, nothing sent")

        try await sse.unsubscribe(contextIds: ["c1", "never"])
        let removed = try XCTUnwrap(node.subscriptions.last)
        XCTAssertEqual(removed["method"] as? String, "unsubscribe")
        XCTAssertEqual(params(removed)["contextIds"] as? [String], ["c1"], "only ids it held")
        XCTAssertFalse(sse.isSubscribed("c1"))
        XCTAssertEqual(sse.subscribedContextIds, ["c2"])
    }

    func testSubscribeBeforeASessionIsSentWithTheConnect() async throws {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))])
        node.install()
        let sse = SseConnection.testing()
        try await sse.subscribe(contextIds: ["c1"], groupIds: ["g1"])
        XCTAssertTrue(node.subscriptions.isEmpty, "no session yet: remembered only")

        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.connect()
        defer { sse.close() }
        _ = await eventually { !log.values.isEmpty }
        let body = try XCTUnwrap(node.subscriptions.first)
        XCTAssertEqual(params(body)["contextIds"] as? [String], ["c1"])
        XCTAssertEqual(params(body)["groupIds"] as? [String], ["g1"])
    }

    func testAConnectWithNothingRememberedPostsNothing() async {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))])
        node.install()
        let sse = SseConnection.testing()
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.connect()
        defer { sse.close() }
        let connected = await eventually { log.values == [.connect("s1")] }
        XCTAssertTrue(connected)
        XCTAssertTrue(node.subscriptions.isEmpty)
    }

    // MARK: - Reconnect

    func testReSubscribesEverythingAfterAReconnectThenAnnouncesIt() async throws {
        let node = ScriptedNode(streams: [
            ScriptedNode.ending(Frames.connect("s1")), ScriptedNode.open(Frames.connect("s2")),
        ])
        node.install()
        let sse = SseConnection.testing()
        sse.remember(contextIds: ["c1"], groupIds: ["g1"])
        let log = SyncLog<SseSeen>()
        let postsAtConnect = SyncLog<Int>()
        sse.on { event in
            if case .connect(let sessionId) = event {
                log.append(.connect(sessionId))
                postsAtConnect.append(node.subscriptions.count)
            }
        }
        sse.connect()
        defer { sse.close() }

        let reconnected = await eventually { log.values == [.connect("s1"), .connect("s2")] }
        XCTAssertTrue(reconnected, "\(log.values)")
        XCTAssertEqual(node.subscriptions.map { $0["id"] as? String }, ["s1", "s2"])
        for body in node.subscriptions {
            XCTAssertEqual(params(body)["contextIds"] as? [String], ["c1"])
            XCTAssertEqual(params(body)["groupIds"] as? [String], ["g1"])
        }
        XCTAssertEqual(postsAtConnect.values, [1, 2], "connect is announced once the re-subscribe has landed")
    }

    func testARefusedReSubscribeAnnouncesConnectThenTheError() async {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))]) { _ in
            .init(status: 500, headers: [:], body: Data("busy".utf8))
        }
        node.install()
        let sse = SseConnection.testing()
        sse.remember(contextIds: ["c1"], groupIds: [])
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.connect()
        defer { sse.close() }
        let seen = await eventually { log.values == [.connect("s1"), .error(500)] }
        XCTAssertTrue(seen, "\(log.values)")
        XCTAssertTrue(sse.isRunning, "a 500 is not terminal")
    }

    func testAReSubscribeThatNeverAnswersGivesUpSoConnectIsNotWithheld() async {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))]) { _ in
            .init(status: 200, headers: [:], body: Data("{}".utf8), delay: 30)
        }
        node.install()
        let sse = SseConnection.testing(postTimeout: 0.2)
        sse.remember(contextIds: ["c1"], groupIds: [])
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.connect()
        defer { sse.close() }
        let seen = await eventually { log.values == [.connect("s1"), .error(nil)] }
        XCTAssertTrue(seen, "\(log.values)")
    }

    func testAForbiddenReSubscribeIsTerminal() async {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))]) { _ in
            .init(status: 403, headers: ["x-auth-error": "token_revoked"], body: Data())
        }
        node.install()
        let sse = SseConnection.testing()
        sse.remember(contextIds: ["c1"], groupIds: [])
        let updates = sse.updates()
        sse.connect()
        do {
            for try await _ in updates {}
            XCTFail("the stream ended without the error")
        } catch {
            guard case MeroError.authRevoked(let reason, let http)? = error as? MeroError else {
                return XCTFail("expected authRevoked, got \(error)")
            }
            XCTAssertEqual(reason, "token_revoked")
            XCTAssertEqual(http.status, 403)
        }
        XCTAssertFalse(sse.isRunning)
        XCTAssertEqual(node.streamOpens, 1, "no reconnect")
        XCTAssertTrue(sse.isSubscribed("c1"), "subscriptions survive, for a later connect()")
    }

    func testARevokedFamilyOnA401IsTerminalButAnExpiredTokenIsNot() {
        let revoked = SseConnection.failure(status: 401, headers: ["x-auth-error": "token_reuse"], url: nil)
        XCTAssertTrue(SseConnection.isTerminal(revoked))
        let expired = SseConnection.failure(status: 401, headers: ["x-auth-error": "token_expired"], url: nil)
        XCTAssertFalse(SseConnection.isTerminal(expired))
        let forbidden = SseConnection.failure(status: 403, headers: [:], url: nil)
        XCTAssertTrue(SseConnection.isTerminal(forbidden), "any 403 stays terminal, as before")
        let busy = MeroError.http(HTTPError(status: 500, statusText: "", url: "", headers: [:]))
        XCTAssertFalse(SseConnection.isTerminal(busy))
    }

    func testBacksOffWhileTheNodeRefusesAndResetsOnceAStreamOpens() async {
        let refused = MockURLProtocol.Stub(status: 503, headers: [:], body: Data())
        let node = ScriptedNode(streams: [
            refused, refused, refused,
            ScriptedNode.ending(Frames.connect("s1")),
            ScriptedNode.open(Frames.connect("s2")),
        ])
        node.install()
        let delays = SyncLog<TimeInterval>()
        let sse = SseConnection.testing(delays: delays)
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.connect()
        defer { sse.close() }
        _ = await eventually { log.values.contains(.connect("s2")) }
        XCTAssertEqual(delays.values, [3, 6, 12, 3], "3 s doubling, back to 3 s after a stream opened")
        XCTAssertEqual(log.values.filter { $0 == .error(503) }.count, 3)
    }

    // MARK: - Backoff policy

    func testBackoffPolicy() {
        let sse = ReconnectBackoff.sse
        XCTAssertEqual(sse.delay(attempt: 0, random: 0.5), 3)
        XCTAssertEqual(sse.delay(attempt: 3, random: 0.5), 24)
        XCTAssertEqual(sse.delay(attempt: 4, random: 0.5), 30, "capped")
        XCTAssertEqual(sse.delay(attempt: 0, random: 0), 2.4, accuracy: 1e-9, "-20%")
        XCTAssertEqual(sse.delay(attempt: 0, random: 0.999_999), 3.6, accuracy: 1e-5, "+20%")
        XCTAssertEqual(sse.delay(attempt: 10, random: 0.999), 30, "never past the cap")
        XCTAssertEqual(sse.delay(attempt: 1000, random: 0.5), 30)

        let ws = ReconnectBackoff.webSocket
        XCTAssertEqual((0..<7).map { ws.delay(attempt: $0, random: 0.9) }, [1, 2, 4, 8, 16, 30, 30])

        let fixed = ReconnectBackoff.fixed(3)
        XCTAssertEqual((0..<4).map { fixed.delay(attempt: $0) }, [3, 3, 3, 3], "mero-js reconnectDelayMs")
    }

    // MARK: - Events

    func testDeliversTypedEventsFromTheWireShape() async throws {
        let started = #"{"fromVersion":"10.1.3","toVersion":"10.2.0","toStateVersion":2,"localContextsTotal":7}"#
        let completed = #"{"toVersion":"10.2.0","completedAt":1700000000}"#
        let joined = #"{"memberAccount":"acct-1","role":"Member"}"#
        let frames =
            Frames.connect("s1")
            + Frames.result(
                #"{"contextId":"ctx1","type":"AppVersionChanged","data":{"fromVersion":"1.0.0","toVersion":"2.0.0"}}"#)
            + Frames.result(#"{"contextId":"ctx1","type":"StateMutation","data":{}}"#)
            + Frames.result(#"{"groupId":"ns-1","type":"MigrationStarted","data":\#(started)}"#)
            + Frames.result(#"{"groupId":"ns-1","type":"MemberJoined","data":\#(joined)}"#)
            + Frames.result(#"{"groupId":"ns-1","type":"MigrationCompleted","data":\#(completed)}"#)
        let node = ScriptedNode(streams: [ScriptedNode.open(frames)])
        node.install()
        let sse = SseConnection.testing()
        let versions = SyncLog<AppVersionChangedEvent>()
        let migrations = SyncLog<GroupMigrationEvent>()
        let members = SyncLog<GroupMembershipEvent>()
        sse.onAppVersionChanged { versions.append($0) }
        let off = sse.onMigrationEvent { migrations.append($0) }
        let membershipTask = Task {
            for try await event in sse.membershipEvents() { members.append(event) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        sse.connect()
        defer { sse.close() }

        let done = await eventually { migrations.values.count == 2 && !members.values.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(
            versions.values, [AppVersionChangedEvent(contextId: "ctx1", fromVersion: "1.0.0", toVersion: "2.0.0")])
        XCTAssertEqual(
            migrations.values,
            [
                .migrationStarted(
                    groupId: "ns-1",
                    MigrationStartedData(
                        fromVersion: "10.1.3", toVersion: "10.2.0", toStateVersion: 2, localContextsTotal: 7)),
                .migrationCompleted(
                    groupId: "ns-1", MigrationCompletedData(toVersion: "10.2.0", completedAt: 1_700_000_000)),
            ])
        XCTAssertEqual(
            members.values,
            [GroupMembershipEvent(groupId: "ns-1", kind: .memberJoined, memberAccount: "acct-1", role: "Member")])
        off()
        membershipTask.cancel()
    }

    func testCloseFinishesListenersAndForgetsSubscriptions() async throws {
        let node = ScriptedNode(streams: [ScriptedNode.open(Frames.connect("s1"))])
        node.install()
        let sse = SseConnection.testing()
        sse.remember(contextIds: ["c1"], groupIds: ["g1"])
        let ended = SyncLog<Bool>()
        let task = Task {
            do {
                for try await _ in sse.updates() {}
                ended.append(true)
            } catch {
                ended.append(false)
            }
        }
        sse.connect()
        _ = await eventually { sse.sessionId == "s1" }
        sse.close()
        let finished = await eventually { ended.values == [true] }
        XCTAssertTrue(finished, "close() ends a listener's stream normally")
        XCTAssertNil(sse.sessionId)
        XCTAssertTrue(sse.subscribedContextIds.isEmpty)
        XCTAssertTrue(sse.subscribedGroupIds.isEmpty)
        XCTAssertFalse(sse.isRunning)
        task.cancel()
    }

    // MARK: - Presence seed

    private func ephemeralFrames() -> String {
        let one = Frames.bytes(#"{"x":1}"#)
        let two = Frames.bytes(#"{"x":2}"#)
        return Frames.connect("s1")
            + Frames.ephemeral("ctx-1", #"{"author":"A","state":\#(one),"ageMs":500}"#)
            + Frames.ephemeral("ctx-1", #"{"author":"B","state":\#(two)}"#)
            + Frames.ephemeral("ctx-1", #"{"author":"B","removed":true}"#)
            + Frames.ephemeral("ctx-other", #"{"author":"C","state":\#(two)}"#)
    }

    func testPresenceSeedKeepsUpsertsDropsRemovalsAndAdvancesAges() async throws {
        let node = ScriptedNode(streams: [ScriptedNode.open(ephemeralFrames())])
        node.install()
        let clock = TestClock()
        let sse = SseConnection.testing(clock: clock)
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.remember(contextIds: ["ctx-1"], groupIds: [])
        sse.connect()
        defer { sse.close() }
        _ = await eventually { log.values.filter { $0 == .event("Ephemeral") }.count == 4 }
        clock.advance(1)

        let seed = sse.presenceSeed("ctx-1")
        XCTAssertEqual(seed.count, 1, "B was removed")
        XCTAssertEqual(seed.first?["author"]?.stringValue, "A")
        XCTAssertEqual(seed.first?["ageMs"]?.doubleValue, 1500, "500 on the node + 1000 since arrival")
        XCTAssertTrue(sse.presenceSeed("ctx-other").isEmpty, "a context this connection does not hold")

        // A late presence subscriber gets the seed first.
        let entries = SyncLog<EphemeralEntry<Point>>()
        let task = Task {
            for try await entry in presenceStream(sse, contextId: "ctx-1", codec: JSONCodec<Point>()) {
                entries.append(entry)
            }
        }
        _ = await eventually { !entries.values.isEmpty }
        XCTAssertEqual(entries.values, [EphemeralEntry(author: "A", state: Point(x: 1), removed: false, ageMs: 1500)])
        task.cancel()

        try await sse.unsubscribe(contextIds: ["ctx-1"])
        XCTAssertTrue(sse.presenceSeed("ctx-1").isEmpty, "an unsubscribed context is forgotten")
    }

    func testANewSessionDropsWhatTheOldOneSaid() async {
        let frames =
            Frames.connect("s1") + Frames.ephemeral("ctx-1", #"{"author":"A","state":[49]}"#) + Frames.connect("s2")
        let node = ScriptedNode(streams: [ScriptedNode.open(frames)])
        node.install()
        let sse = SseConnection.testing()
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.remember(contextIds: ["ctx-1"], groupIds: [])
        sse.connect()
        defer { sse.close() }
        _ = await eventually { log.values.contains(.connect("s2")) }
        XCTAssertTrue(sse.presenceSeed("ctx-1").isEmpty, "the re-subscribe brings a fresh replay")
    }
}

struct Point: Codable, Equatable, Sendable {
    let x: Int
}
