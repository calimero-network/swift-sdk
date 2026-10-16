import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Local-node discovery. (Port of mero-js `nodeDiscovery.test.ts`.)
final class NodeDiscoveryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private let session = MockURLProtocol.makeSession()

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// Only the given bases answer their health endpoint; every other request
    /// is refused, the way a closed local port is.
    private func healthy(_ bases: Set<String>, status: String = "alive") -> AuthorizationLog {
        let probed = AuthorizationLog()
        MockURLProtocol.setHandler { req in
            let full = req.url?.absoluteString ?? ""
            probed.append(full)
            let base = full.components(separatedBy: "/admin-api/").first ?? ""
            guard full.hasSuffix("/admin-api/health"), bases.contains(base) else {
                return .init(status: 502, headers: [:], body: Data())
            }
            return .init(
                status: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"data":{"status":"\#(status)"}}"#.utf8))
        }
        return probed
    }

    private func answer(_ status: Int, _ body: String) {
        MockURLProtocol.setHandler { _ in .init(status: status, headers: [:], body: Data(body.utf8)) }
    }

    // MARK: - URLs

    func testLocalNodeURL() {
        XCTAssertEqual(NodeDiscovery.localNodeURL(port: 2428).absoluteString, "http://localhost:2428")
    }

    func testNodeEndpointAppendsThePathToARootBase() {
        XCTAssertEqual(
            NodeDiscovery.nodeEndpoint(url("http://localhost:2428"), path: "admin-api/health").absoluteString,
            "http://localhost:2428/admin-api/health")
    }

    func testNodeEndpointPreservesAPathPrefix() {
        XCTAssertEqual(
            NodeDiscovery.nodeEndpoint(url("http://host/node1"), path: "admin-api/health").absoluteString,
            "http://host/node1/admin-api/health")
    }

    func testNodeEndpointDoesNotDoubleTheSlash() {
        XCTAssertEqual(
            NodeDiscovery.nodeEndpoint(url("http://host/node1/"), path: "admin-api/health").absoluteString,
            "http://host/node1/admin-api/health")
    }

    // MARK: - probeNodeHealth

    func testAliveIsHealthy() async {
        _ = healthy(["http://localhost:2428"])
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertTrue(ok)
    }

    func testANonJSONTwoHundredIsAlive() async {
        answer(200, "OK")
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertTrue(ok)
    }

    func testAStatusOtherThanAliveIsNot() async {
        _ = healthy(["http://localhost:2428"], status: "not_alive")
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertFalse(ok)
    }

    func testAnExplicitNullStatusIsNot() async {
        answer(200, #"{"data":{"status":null}}"#)
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertFalse(ok)
    }

    func testATwoHundredWithNoStatusIsAlive() async {
        answer(200, "{}")
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertTrue(ok)
    }

    func testAPlainTopLevelStatusIsRead() async {
        answer(200, #"{"status":"Alive"}"#)
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertTrue(ok)
    }

    func testACancelledTaskIsFalseWithoutFetching() async {
        let probed = healthy(["http://localhost:2428"])
        let session = self.session
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await NodeDiscovery.probeNodeHealth(URL(string: "http://localhost:2428")!, session: session)
        }
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(probed.values.count, 0)
    }

    func testANonOkResponseIsNot() async {
        answer(503, "{}")
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertFalse(ok)
    }

    func testANetworkErrorIsNot() async {
        MockURLProtocol.reset()  // no handler: the request fails in the transport
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:9999"), session: session)
        XCTAssertFalse(ok)
    }

    func testAHangingNodeTimesOut() async {
        MockURLProtocol.setHandler { _ in .init(status: 200, headers: [:], body: Data("{}".utf8), delay: 10) }
        let started = Date()
        let ok = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), timeout: 0.2, session: session)
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testHitsTheHealthPathOfTheBase() async {
        let probed = healthy(["http://localhost:2428"])
        _ = await NodeDiscovery.probeNodeHealth(url("http://localhost:2428"), session: session)
        XCTAssertEqual(probed.values, ["http://localhost:2428/admin-api/health"])
    }

    // MARK: - discoverLocalNodes

    func testReturnsOnlyTheHealthyNodesInPortOrder() async {
        _ = healthy(["http://localhost:2528", "http://localhost:2428"])
        let nodes = await NodeDiscovery.discoverLocalNodes(session: session)
        XCTAssertEqual(nodes.map(\.absoluteString), ["http://localhost:2428", "http://localhost:2528"])
    }

    func testReturnsNothingWhenNothingLocalRuns() async {
        _ = healthy([])
        let nodes = await NodeDiscovery.discoverLocalNodes(session: session)
        XCTAssertEqual(nodes, [])
    }

    func testProbesExactlyTheDefaultPorts() async {
        let probed = healthy([])
        _ = await NodeDiscovery.discoverLocalNodes(session: session)
        XCTAssertEqual(NodeDiscovery.defaultLocalNodePorts, [2428, 2429, 2528, 2529])
        XCTAssertEqual(
            Set(probed.values.compactMap { $0 }),
            Set(NodeDiscovery.defaultLocalNodePorts.map { "http://localhost:\($0)/admin-api/health" }))
        XCTAssertEqual(probed.values.count, NodeDiscovery.defaultLocalNodePorts.count)
    }

    func testRespectsACustomPortList() async {
        let probed = healthy(["http://localhost:3000"])
        let nodes = await NodeDiscovery.discoverLocalNodes(ports: [3000, 3001], session: session)
        XCTAssertEqual(nodes.map(\.absoluteString), ["http://localhost:3000"])
        XCTAssertEqual(probed.values.count, 2)
    }
}
