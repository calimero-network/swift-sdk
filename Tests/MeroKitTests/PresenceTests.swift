import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The device-signed presence statement (port of mero-js `statement.test.ts`).
final class PresenceStatementTests: XCTestCase {
    /// core's `statement_vector_is_stable` (calimero-node-primitives, presence.rs).
    static let coreVector =
        "63616c696d65726f2f70726573656e63652f31"
        + "1111111111111111111111111111111111111111111111111111111111111111"
        + "a09aa5f47a6759802ff955f8dc2d2a14a5c99d23be97f864127ff9383455a4f0"
        + "0700000000000000" + "0068e5cf8b010000"
        + "f25c119b355e48fcfc5c8acd6b7681d0d8dfe33f75ee6408aa162e13b05ca486"

    private func author() throws -> String {
        Hex.encode(try Ed25519.publicKey(seed: Data(repeating: 0x22, count: 32)))
    }

    func testMatchesCoresPinnedBytes() throws {
        let bytes = try PresenceStatement.bytes(
            contextId: String(repeating: "11", count: 32), author: try author(), seq: 7, sentAtMs: 1_700_000_000_000,
            state: Data(#"{"typing":true}"#.utf8))
        XCTAssertEqual(Hex.encode(bytes), Self.coreVector)
    }

    func testTheDomainIsCalimeroPresence1() {
        XCTAssertEqual(String(decoding: PresenceStatement.domain, as: UTF8.self), "calimero/presence/1")
    }

    func testHashesARetractDifferentlyFromAnEmptyState() {
        XCTAssertNotEqual(PresenceStatement.stateHash(nil), PresenceStatement.stateHash(Data()))
        XCTAssertEqual(PresenceStatement.stateHash(nil), sha256(Data([0])))
        XCTAssertEqual(PresenceStatement.stateHash(Data()), sha256(Data([1, 0, 0, 0, 0])))
    }

    func testRefusesAShortContextId() {
        XCTAssertThrowsError(
            try PresenceStatement.bytes(contextId: "11", author: try author(), seq: 1, sentAtMs: 1, state: nil))
    }

    func testSignedIntentVerifiesAgainstTheStatement() throws {
        let keys = try presenceTestKeys()
        let context = String(repeating: "11", count: 32)
        let state = Data(#"{"typing":true}"#.utf8)
        let intent = try PresenceStatement.signedIntent(
            contextId: context, state: state, seq: 7, sentAtMs: 1_700_000_000_000, keys: keys, authorProof: "aa")
        XCTAssertEqual(intent.state, Hex.encode(state))
        XCTAssertEqual(intent.seq, 7)
        XCTAssertEqual(intent.authorProof, "aa")
        let signature = try Hex.decodeUnsized(intent.signature, label: "signature")
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: try Hex.decode(keys.signPublicKey, label: "key", bytes: 32), signature: signature,
                message: try Hex.decodeUnsized(Self.coreVector, label: "vector")))

        let retract = try PresenceStatement.signedIntent(
            contextId: context, state: nil, seq: 8, sentAtMs: 1, keys: keys, authorProof: "aa")
        XCTAssertNil(retract.state)
    }
}

/// A relay that records presence posts and answers with scripted statuses.
final class FakePresenceRelay: PresenceRelay, @unchecked Sendable {
    struct Sent: Equatable {
        let contextId: String
        let state: Data?
        let seq: UInt64
        let sentAtMs: UInt64
    }

    let authorKey = String(repeating: "22", count: 32)
    let calls = SyncLog<Sent>()
    private let lock = NSLock()
    private var statuses: [Int?]
    private var gate: CheckedContinuation<Void, Never>?
    private var holdFirst: Bool
    private var released = false

    init(statuses: [Int?] = [], holdFirst: Bool = false) {
        self.statuses = statuses
        self.holdFirst = holdFirst
    }

    /// Let a held first post answer.
    func release() {
        lock.lock()
        let pending = gate
        gate = nil
        released = true
        lock.unlock()
        pending?.resume()
    }

    func presenceIntent(contextId: String, state: Data?, seq: UInt64, sentAtMs: UInt64) async throws {
        calls.append(Sent(contextId: contextId, state: state, seq: seq, sentAtMs: sentAtMs))
        lock.lock()
        let hold = holdFirst
        holdFirst = false
        let status = statuses.isEmpty ? nil : statuses.removeFirst()
        lock.unlock()
        if hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    gate = continuation
                    lock.unlock()
                }
            }
        }
        if let status {
            throw MeroError.http(HTTPError(status: status, statusText: "S", url: "u", headers: [:]))
        }
    }
}

/// Port of mero-js `relay-presence.test.ts`, with a 50 ms heartbeat.
final class RelayPresenceClientTests: XCTestCase {
    private let context = String(repeating: "11", count: 32)
    private let heartbeat: TimeInterval = 0.05

    private struct Typing: Codable, Sendable, Equatable {
        let typing: Bool
    }

    private func client(_ relay: FakePresenceRelay, now: UInt64 = 1_000) -> RelayPresenceClient {
        RelayPresenceClient(relay: relay, events: { nil }, heartbeat: heartbeat, nowMs: { now })
    }

    private func pause(_ heartbeats: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(heartbeats * heartbeat * 1_000_000_000))
    }

    func testResendsWithARisingSeqAndOneRetractStopsIt() async throws {
        let relay = FakePresenceRelay()
        let presence = client(relay)
        try await presence.set(contextId: context, state: Typing(typing: true))
        _ = await eventually { relay.calls.values.count >= 3 }
        let seqs = relay.calls.values.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count, "strictly rising")
        XCTAssertEqual(seqs.first, 1_000)

        try await presence.set(contextId: context, state: Typing?.none)
        let after = relay.calls.values.count
        XCTAssertNil(relay.calls.values.last?.state, "the retract sends state: nil")
        await pause(5)
        XCTAssertEqual(relay.calls.values.count, after, "no resend after a retract")
        let heartbeating = await presence.isHeartbeating(context)
        XCTAssertFalse(heartbeating)
    }

    func testSendsTheEncodedState() async throws {
        let relay = FakePresenceRelay()
        let presence = client(relay)
        try await presence.set(contextId: context, state: Typing(typing: true))
        XCTAssertEqual(relay.calls.values.first?.state, Data(#"{"typing":true}"#.utf8))
        await presence.close()
    }

    func testSeedsSeqFromTheWallClock() async throws {
        let relay = FakePresenceRelay()
        let presence = client(relay, now: 1_700_000_000_000)
        try await presence.set(contextId: context, state: Typing(typing: false))
        XCTAssertEqual(relay.calls.values.first?.seq, 1_700_000_000_000)
        XCTAssertEqual(relay.calls.values.first?.sentAtMs, 1_700_000_000_000)
        await presence.close()
    }

    func testDoesNotThrowA429AndStopsResendingAfterA403() async throws {
        let relay = FakePresenceRelay(statuses: [429, 403])
        let presence = client(relay)
        try await presence.set(contextId: context, state: Typing(typing: true))
        XCTAssertEqual(relay.calls.values.count, 1, "a 429 is not retried at once")
        _ = await eventually { relay.calls.values.count == 2 }
        await pause(5)
        XCTAssertEqual(relay.calls.values.count, 2, "the resend's 403 stops the resends")
    }

    func testThrowsA403FromSetAndSendsNothingMore() async {
        let relay = FakePresenceRelay(statuses: [403])
        let presence = client(relay)
        do {
            try await presence.set(contextId: context, state: Typing(typing: true))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? MeroError)?.httpStatus, 403)
        }
        await pause(5)
        XCTAssertEqual(relay.calls.values.count, 1)
    }

    func testCloseStopsEveryResend() async throws {
        let relay = FakePresenceRelay()
        let presence = client(relay)
        try await presence.set(contextId: context, state: Typing(typing: true))
        await presence.close()
        await pause(5)
        XCTAssertEqual(relay.calls.values.count, 1)
    }

    func testSubscribingWithoutAnEventConnectionFails() async {
        let presence = client(FakePresenceRelay())
        do {
            for try await _ in presence.subscribe(contextId: context, as: Typing.self) {}
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue("\(error)".contains("no event connection"), "\(error)")
        }
    }

    func testARetractMadeWhileAnEarlierSetIsInFlightIsNotUndoneByIt() async throws {
        let relay = FakePresenceRelay(holdFirst: true)
        let presence = client(relay)
        let context = self.context
        let typing = Task { try await presence.set(contextId: context, state: Typing(typing: true)) }
        _ = await eventually { relay.calls.values.count == 1 }
        try await presence.set(contextId: context, state: Typing?.none)
        relay.release()
        try await typing.value
        await pause(5)
        XCTAssertEqual(relay.calls.values.map { $0.state == nil }, [false, true])
    }

    func testTwoOverlappingSetsLeaveOneHeartbeatWhichCloseStops() async throws {
        let relay = FakePresenceRelay()
        let presence = client(relay)
        let context = self.context
        async let first: Void = presence.set(contextId: context, state: Typing(typing: true))
        async let second: Void = presence.set(contextId: context, state: Typing(typing: false))
        _ = try await (first, second)
        await presence.close()
        let sent = relay.calls.values.count
        await pause(5)
        XCTAssertEqual(relay.calls.values.count, sent)
    }

    func testKeepsResendingAfterATransientFailureOfTheFirstSend() async throws {
        for status in [503, 0] {
            let relay = FakePresenceRelay(statuses: [status])
            let presence = client(relay)
            try await presence.set(contextId: context, state: Typing(typing: true))
            let resent = await eventually { relay.calls.values.count >= 2 }
            XCTAssertTrue(resent, "status \(status)")
            await presence.close()
        }
    }

    func testStopsResendingOnA400() async throws {
        let relay = FakePresenceRelay(statuses: [nil, 400])
        let presence = client(relay)
        try await presence.set(contextId: context, state: Typing(typing: true))
        _ = await eventually { relay.calls.values.count == 2 }
        await pause(5)
        XCTAssertEqual(relay.calls.values.count, 2)
    }

    func testANetworkFailureIsTransientButAnUnsignableStatementIsNot() {
        XCTAssertTrue(RelayPresenceClient.isTransient(MeroError.network("offline")))
        XCTAssertTrue(RelayPresenceClient.isTransient(URLError(.timedOut)))
        XCTAssertFalse(RelayPresenceClient.isTransient(AccountError.invalidInput("contextId must be 64 hex")))
    }
}

/// `RelayClient.presenceIntent` signs and posts what core expects.
final class RelayPresenceIntentTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testSignsWithTheDeviceKeyAndPostsTheExactBody() async throws {
        let bodies = SyncLog<CapturedRequest>()
        MockURLProtocol.setHandler { req in
            bodies.append(
                CapturedRequest(
                    method: req.httpMethod ?? "", path: req.url?.path ?? "", query: nil, body: FakeNode.body(req)))
            return .init(status: 204, headers: [:], body: Data())
        }
        let keys = try presenceTestKeys()
        let relay = RelayClient(
            relayURL: "https://relay.test/", authorAccount: String(repeating: "ab", count: 32), authorProof: "cafe",
            keys: keys, nonces: MemoryWarrantNonceStore(), session: MockURLProtocol.makeSession())
        XCTAssertEqual(relay.authorKey, keys.signPublicKey)
        let context = String(repeating: "11", count: 32)
        try await relay.presenceIntent(
            contextId: context, state: Data(#"{"typing":true}"#.utf8), seq: 7, sentAtMs: 1_700_000_000_000)

        let request = try XCTUnwrap(bodies.values.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/admin-api/contexts/\(context)/presence-intents")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(Set(body.keys), ["state", "seq", "sentAtMs", "signature", "authorProof"])
        XCTAssertEqual(body["state"] as? String, Hex.encode(Data(#"{"typing":true}"#.utf8)))
        XCTAssertEqual((body["seq"] as? NSNumber)?.uint64Value, 7)
        XCTAssertEqual((body["sentAtMs"] as? NSNumber)?.uint64Value, 1_700_000_000_000)
        XCTAssertEqual(body["authorProof"] as? String, "cafe")
        let signature = try Hex.decodeUnsized(try XCTUnwrap(body["signature"] as? String), label: "signature")
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: try Hex.decode(keys.signPublicKey, label: "key", bytes: 32), signature: signature,
                message: try Hex.decodeUnsized(PresenceStatementTests.coreVector, label: "vector")),
            "the signature covers core's statement bytes")

        try await relay.presenceIntent(contextId: context, state: nil, seq: 8, sentAtMs: 1)
        let retract = try XCTUnwrap(bodies.values.last?.jsonBody)
        XCTAssertTrue(retract["state"] is NSNull, "a retract sends state: null, not an absent field")
    }

    func testAdminApiSignsThePresenceIntentForTheCaller() async throws {
        let recorder = RequestRecorder()
        recorder.install()
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://relay.test")!, timeout: 5),
            session: MockURLProtocol.makeSession())
        let keys = try presenceTestKeys()
        let context = String(repeating: "11", count: 32)
        try await mero.admin.postPresenceIntent(
            context, state: nil, seq: 9, sentAtMs: 10, keys: keys, authorProof: "cafe")
        let body = try XCTUnwrap(recorder.requests.first?.jsonBody)
        XCTAssertTrue(body["state"] is NSNull)
        XCTAssertEqual((body["signature"] as? String)?.count, 128)
    }

    func testACloudConnectionWithARelayHasPresence() {
        let keys = DeviceKeys.generate()
        let session = CloudSession(account: "aa", device: "bb", credential: "cc", relayUrl: "https://relay.test")
        let relay = RelayClient(
            relayURL: "https://relay.test", authorAccount: "aa", authorProof: "cc", keys: keys,
            nonces: MemoryWarrantNonceStore())
        let connected = CloudConnection(session: session, relay: relay, mero: nil, nodeKey: nil, readNote: nil)
        XCTAssertNotNil(connected.presence)
        let relayless = CloudConnection(session: session, relay: nil, mero: nil, nodeKey: nil, readNote: nil)
        XCTAssertNil(relayless.presence)
    }
}

/// The device keys of core's vector: signing seed `0x22 * 32`.
func presenceTestKeys() throws -> DeviceKeys {
    try DeviceKeys(signSecret: Data(repeating: 0x22, count: 32), kemSecret: Data(repeating: 1, count: 32))
}
