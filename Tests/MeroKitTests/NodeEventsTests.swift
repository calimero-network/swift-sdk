import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Typed group/node event streams (== Kotlin `groupEvents` / `nodeEvents`)
/// and `Mero.close()` ending the streams an instance started.
final class NodeEventsTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private let frames =
        "data: {\"type\":\"connect\",\"session_id\":\"s1\"}\n\n"
        + "data: {\"result\":{\"groupId\":\"g1\",\"type\":\"MemberAdded\",\"data\":{\"memberAccount\":\"aa\"}}}\n\n"
        + "data: {\"result\":{\"contextId\":\"c1\",\"type\":\"StateMutation\",\"data\":{\"events\":[]}}}\n\n"
        + "data: {\"result\":{\"groupId\":\"g1\",\"type\":\"MigrationCompleted\"}}\n\n"

    private func serveFrames() -> RequestRecorder {
        let recorded = RequestRecorder()
        let frames = self.frames
        MockURLProtocol.setHandler { req in
            recorded.append(req)
            if req.url?.path == "/sse" {
                return .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(frames.utf8))
            }
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        return recorded
    }

    private func client() -> SseClient {
        SseClient(baseURL: URL(string: "https://node.test")!, token: { "T" }, session: MockURLProtocol.makeSession())
    }

    func testNodeEventsDeliversBothKindsTyped() async throws {
        let recorded = serveFrames()
        var events: [NodeEvent] = []
        for try await event in client().nodeEvents(contextIds: ["c1"], groupIds: ["g1"]) {
            events.append(event)
            if events.count == 3 { break }
        }
        guard events.count == 3 else { return XCTFail("got \(events.count) events") }
        guard case .group(let added) = events[0], case .context(let mutation) = events[1],
            case .group(let completed) = events[2]
        else { return XCTFail("wrong order or kinds: \(events)") }
        XCTAssertEqual(added.groupId, "g1")
        XCTAssertEqual(added.kind, "MemberAdded")
        XCTAssertEqual(added.payload["data"]?["memberAccount"]?.stringValue, "aa")
        XCTAssertEqual(mutation.contextId, "c1")
        XCTAssertEqual(mutation.kind, "StateMutation")
        XCTAssertEqual(completed.kind, "MigrationCompleted")

        let subscribe = recorded.requests.first { $0.path == "/sse/subscription" }
        let params = subscribe?.jsonBody?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(params["contextIds"] as? [String], ["c1"])
        XCTAssertEqual(params["groupIds"] as? [String], ["g1"])
    }

    func testGroupEventsDropsContextEventsAndSubscribesNoContexts() async throws {
        let recorded = serveFrames()
        var kinds: [String] = []
        for try await event in client().groupEvents(groupIds: ["g1"]) {
            XCTAssertEqual(event.groupId, "g1")
            kinds.append(event.kind)
            if kinds.count == 2 { break }
        }
        XCTAssertEqual(
            kinds, ["MemberAdded", "MigrationCompleted"], "the StateMutation in between is not a group event")
        let subscribe = recorded.requests.first { $0.path == "/sse/subscription" }
        let params = subscribe?.jsonBody?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(params["contextIds"] as? [String], [])
        XCTAssertEqual(params["groupIds"] as? [String], ["g1"])
    }

    func testEventsStillYieldsGroupEventsUntyped() async throws {
        _ = serveFrames()
        var first: ContextEvent?
        for try await event in client().events(contextIds: ["c1"], groupIds: ["g1"]) {
            first = event
            break
        }
        XCTAssertEqual(first?.groupId, "g1")
        XCTAssertEqual(first?.contextId, "")
    }

    func testFrameParsing() {
        let context = SseClient.nodeEvent(["contextId": "c", "type": "SyncStatus"])
        guard case .context(let event)? = context else { return XCTFail("\(String(describing: context))") }
        XCTAssertEqual(event.kind, "SyncStatus")
        XCTAssertNil(event.groupId)

        let group = SseClient.nodeEvent(["groupId": "g", "type": "MemberRemoved"])
        guard case .group(let groupEvent)? = group else { return XCTFail("\(String(describing: group))") }
        XCTAssertEqual(groupEvent.groupId, "g")
        XCTAssertEqual(groupEvent.kind, "MemberRemoved")
        XCTAssertEqual(groupEvent.payload["type"]?.stringValue, "MemberRemoved")
        XCTAssertEqual(group?.contextEvent.groupId, "g")

        XCTAssertNil(SseClient.nodeEvent(["type": "Orphan"]), "names neither a context nor a group")
        let untyped = SseClient.nodeEvent(["contextId": "c"])
        XCTAssertEqual(untyped?.contextEvent.kind, "event")
    }

    // MARK: - close()

    /// A `/sse` that never answers: the stream is live but silent.
    private func hangingNode() {
        MockURLProtocol.setHandler { _ in
            .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(), delay: 60)
        }
    }

    private func finishes(_ task: Task<Void, Never>, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            if !first { task.cancel() }  // don't leave the test hanging on a failure
            group.cancelAll()
            return first
        }
    }

    func testCloseEndsEveryLiveStream() async throws {
        hangingNode()
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5),
            session: MockURLProtocol.makeSession())
        await mero.setTokenData(
            TokenData(accessToken: "T", refreshToken: "R", expiresAt: Date().addingTimeInterval(3600)))

        let contexts = Task {
            do { for try await _ in mero.events(contextIds: ["c1"]) {} } catch {}
        }
        let groups = Task {
            do { for try await _ in mero.groupEvents(groupIds: ["g1"]) {} } catch {}
        }
        let both = Task {
            do { for try await _ in mero.nodeEvents(contextIds: ["c1"], groupIds: ["g1"]) {} } catch {}
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        await mero.close()

        let ended = await [
            finishes(contexts, within: 3), finishes(groups, within: 3), finishes(both, within: 3),
        ]
        XCTAssertEqual(ended, [true, true, true])
    }

    func testCloseWithNoStreamsIsHarmlessAndLaterStreamsStillWork() async throws {
        let mero = Mero(
            config: MeroConfig(baseURL: URL(string: "https://node.test")!, timeout: 5),
            session: MockURLProtocol.makeSession())
        await mero.close()
        _ = serveFrames()
        await mero.setTokenData(
            TokenData(accessToken: "T", refreshToken: "R", expiresAt: Date().addingTimeInterval(3600)))
        var first: GroupEvent?
        for try await event in mero.groupEvents(groupIds: ["g1"]) {
            first = event
            break
        }
        XCTAssertEqual(first?.kind, "MemberAdded")
    }

    func testRegistryForgetsAStreamThatEndedOnItsOwn() async throws {
        _ = serveFrames()
        let registry = SseStreamRegistry()
        let sse = SseClient(
            baseURL: URL(string: "https://node.test")!, token: { "T" }, session: MockURLProtocol.makeSession(),
            registry: registry)
        for try await _ in sse.groupEvents(groupIds: ["g1"]) {
            XCTAssertEqual(registry.count, 1)
            break
        }
        // Breaking out terminates the stream; its entry goes with it.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(registry.count, 0)
    }
}
