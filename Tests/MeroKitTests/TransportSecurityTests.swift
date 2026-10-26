import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Plain http only to local hosts (SEC-06). (== Kotlin `TransportSecurityTest`.)
final class TransportSecurityTests: XCTestCase {
    override func tearDown() {
        TransportSecurity.allowInsecureHTTP = false
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testLocalHosts() {
        for host in [
            "localhost", "127.0.0.1", "127.8.9.10", "::1", "[::1]", "10.0.2.2", "10.1.2.3", "172.16.0.1",
            "172.31.255.255", "192.168.1.5", "169.254.10.20", "fe80::1", "[fe80::1%en0]", "fd12:3456::1",
            "merod.local", "node.localhost", "LOCALHOST",
        ] {
            XCTAssertTrue(TransportSecurity.isLocalHost(host), host)
        }
        for host in [
            "node.example", "8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.1.1", "11.0.0.1", "2001:db8::1",
            "local", "evil-local.com", "1.2.3", "", "127.0.0.1.example.com",
        ] {
            XCTAssertFalse(TransportSecurity.isLocalHost(host), host)
        }
    }

    func testLoopbackHosts() {
        for host in ["localhost", "127.0.0.1", "::1", "[::1]", "10.0.2.2"] {
            XCTAssertTrue(TransportSecurity.isLoopbackHost(host), host)
        }
        for host in ["192.168.1.5", "10.0.0.1", "merod.local", "node.example"] {
            XCTAssertFalse(TransportSecurity.isLoopbackHost(host), host)
        }
    }

    func testIsSecureOrLocal() {
        XCTAssertTrue(TransportSecurity.isSecureOrLocal("https://node.example"))
        XCTAssertTrue(TransportSecurity.isSecureOrLocal("wss://node.example/ws"))
        XCTAssertTrue(TransportSecurity.isSecureOrLocal("http://localhost:2428"))
        XCTAssertTrue(TransportSecurity.isSecureOrLocal("http://192.168.1.5:2428"))
        XCTAssertFalse(TransportSecurity.isSecureOrLocal("http://node.example"))
        XCTAssertFalse(TransportSecurity.isSecureOrLocal("ws://node.example"))
        XCTAssertFalse(TransportSecurity.isSecureOrLocal("ftp://localhost"))
        XCTAssertFalse(TransportSecurity.isSecureOrLocal("not a url"))
    }

    func testANodeMayBePlainHttpOnlyWhenLocal() throws {
        try TransportSecurity.checkNodeURL(URL(string: "https://node.example")!)
        try TransportSecurity.checkNodeURL(URL(string: "http://localhost:2428")!)
        try TransportSecurity.checkNodeURL(URL(string: "http://192.168.1.5:2428")!)
        try TransportSecurity.checkNodeURL(URL(string: "http://10.0.2.2:2428")!)
        XCTAssertThrowsError(try TransportSecurity.checkNodeURL(URL(string: "http://node.example/auth?t=secret")!)) {
            let refused = $0 as? InsecureTransportError
            XCTAssertEqual(refused?.role, "node")
            XCTAssertEqual(refused?.url, "http://node.example/auth", "the query is not echoed")
        }
        XCTAssertThrowsError(try TransportSecurity.checkNodeURL(URL(string: "ws://node.example/ws")!))
    }

    func testAServiceMustBeHttpsUnlessLoopback() throws {
        try TransportSecurity.checkServiceURL(URL(string: "https://cloud.example")!, role: "cloud")
        try TransportSecurity.checkServiceURL(URL(string: "http://127.0.0.1:8080")!, role: "cloud")
        try TransportSecurity.checkServiceURL(URL(string: "http://10.0.2.2:8080")!, role: "relay")
        XCTAssertThrowsError(try TransportSecurity.checkServiceURL(URL(string: "http://192.168.1.5")!, role: "relay"))
        XCTAssertThrowsError(try TransportSecurity.checkServiceURL(URL(string: "http://cloud.example")!, role: "cloud"))
    }

    func testTheDevelopmentOptInLiftsBothRules() throws {
        TransportSecurity.allowInsecureHTTP = true
        try TransportSecurity.checkNodeURL(URL(string: "http://node.example")!)
        try TransportSecurity.checkServiceURL(URL(string: "http://cloud.example")!, role: "cloud")
    }

    func testTheNodeClientRefusesPlainHttpAcrossTheNetworkBeforeSending() async {
        let sent = Counter()
        MockURLProtocol.setHandler { _ in
            _ = sent.increment()
            return .init(status: 200, headers: [:], body: Data("{}".utf8))
        }
        let http = URLSessionHttpClient(
            baseURL: URL(string: "http://node.example")!, session: MockURLProtocol.makeSession())
        do {
            try await http.sendVoid(HttpRequest(path: "/auth/token", method: .post))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error is InsecureTransportError, "\(error)")
        }
        XCTAssertEqual(sent.count, 0, "nothing left the device")

        let local = URLSessionHttpClient(
            baseURL: URL(string: "http://localhost:2428")!, session: MockURLProtocol.makeSession())
        try? await local.sendVoid(HttpRequest(path: "/auth/token", method: .post))
        XCTAssertEqual(sent.count, 1)
    }

    func testTheCloudAndTheWalletMustBeHttps() async {
        do {
            _ = try await RelayNodeKey.attest(
                relayURL: "http://relay.example", verifier: DcapRelayKeyVerifier(allowMock: true),
                session: MockURLProtocol.makeSession())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? InsecureTransportError)?.role, "relay")
        }
        XCTAssertThrowsError(try cloudNodeReleaseUrl("http://mirror.example", version: "2.3.99"))
        XCTAssertThrowsError(
            try DeviceEnrolment.url(
                walletURL: URL(string: "http://wallet.example")!, devicePublicKey: String(repeating: "a", count: 64),
                kemPublicKey: String(repeating: "b", count: 64), callbackURL: "https://app.example/enrol", state: nil))
    }
}
