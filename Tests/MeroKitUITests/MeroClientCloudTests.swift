import MeroKit
import MeroKitTestSupport
import XCTest

@testable import MeroKitUI

/// A wallet that answers the auth sheet in-process: it reads the device keys
/// and `state` off the wallet URL and certifies them with a test root — so the
/// real verification path runs, with no browser.
private struct InProcessWallet: WebAuthenticating {
    var decline = false
    var tamperState = false

    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        if decline { return URL(string: "\(callback.url)#error=cancelled")! }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let root = Data(repeating: 0x5C, count: 32)
        let account = try DeviceCertificates.account(forRootPublicKey: Hex.encode(try Ed25519.publicKey(seed: root)))
        let device = try DeviceCertificates.mintDeviceId(account: account, nonce: Data(repeating: 0xA1, count: 16))
        let credential = try DeviceCertificates.certify(
            rootSeed: root, device: device, signPublicKey: item("enrol-device"), kemPublicKey: item("enrol-kem"))
        let state = tamperState ? "forged" : item("state")
        return URL(
            string:
                "\(item("callback-url"))#credential=\(credential)&account=\(account)&device=\(device)&state=\(state)")!
    }
}

@MainActor
final class MeroClientCloudTests: XCTestCase {
    private let relay = "https://relay.test"

    override func setUp() {
        super.setUp()
        MockURLProtocol.setHandler { req in
            let path = req.url?.path ?? ""
            func json(_ s: String) -> MockURLProtocol.Stub {
                .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
            }
            if path.hasSuffix("/challenge"), path.hasPrefix("/api/cloud/") { return json(#"{"nonce":"n"}"#) }
            if path.hasSuffix("/relays") {
                return json(#"{"relays":[{"peer_id":"p","relay_url":"https://relay.test","fresh":true}]}"#)
            }
            if path == "/admin-api/tee/attest" {
                let body = (try? JSONSerialization.jsonObject(with: FakeNode.body(req))) as? [String: Any]
                let nonce = (try? Hex.decode(body?["nonce"] as? String ?? "", label: "n", bytes: 32)) ?? Data()
                let key = try! Ed25519.publicKey(seed: Data(repeating: 0x42, count: 32))
                let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(key)
                return json(
                    #"{"data":{"quoteB64":"\#(quote.base64EncodedString())","boundPublicKey":"\#(Hex.encode(key))"}}"#)
            }
            if path == "/auth/challenge" {
                return json(#"{"data":{"challenge":"\#(String(repeating: "c4", count: 32))"}}"#)
            }
            if path == "/auth/token" { return json(#"{"data":{"access_token":"a","refresh_token":"r"}}"#) }
            if path == "/auth/logout" { return json(#"{"data":{"success":true}}"#) }
            if path.hasSuffix("/query") { return json(#"{"data":{"returns":42}}"#) }
            return .init(status: 404, headers: [:], body: Data())
        }
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(wallet: InProcessWallet = InProcessWallet()) -> MeroClient {
        let session = MockURLProtocol.makeSession()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true)),
            keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore(), urlSession: session)
        return MeroClient(session: session, cloud: cloud, webAuthenticator: wallet)
    }

    func testCloudSignInPublishesAccountAndRelay() async {
        let client = makeClient()
        await client.signInWithCloud(callbackScheme: "mero-sample")

        XCTAssertNil(client.errorMessage)
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(client.relayURL, relay)
        XCTAssertFalse(client.isSignedInWithoutRelay)
        XCTAssertEqual(client.account?.count, 64)
        XCTAssertNotNil(client.connection?.mero, "the relay session was minted")

        await client.runSampleRpc(contextId: String(repeating: "11", count: 32), method: "get")
        XCTAssertEqual(client.lastRpcResult, "number(42.0)")

        await client.logout()
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(client.account)
    }

    func testDeclineShowsAFriendlyErrorAndStaysSignedOut() async {
        let client = makeClient(wallet: InProcessWallet(decline: true))
        await client.signInWithCloud(callbackScheme: "mero-sample")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(client.errorMessage, "This device was not approved. You can try again.")
    }

    func testAForgedStateIsRefused() async {
        let client = makeClient(wallet: InProcessWallet(tamperState: true))
        await client.signInWithCloud(callbackScheme: "mero-sample")
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNotNil(client.errorMessage)
    }

    func testHandleEnrolmentCallbackIgnoresUnrelatedURLs() async {
        let client = makeClient()
        let handled = await client.handleEnrolmentCallback(URL(string: "mero-sample://somewhere")!)
        XCTAssertFalse(handled)
        XCTAssertFalse(client.isAuthenticated)
    }

    func testRestoreReconnectsAStoredSession() async {
        let session = MockURLProtocol.makeSession()
        let sessions = AnyValueStore<CloudSession>.memory()
        let keys = AnyValueStore<DeviceKeys>.memory()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true)),
            keyStore: keys, sessionStore: sessions, nonces: MemoryWarrantNonceStore(), urlSession: session)
        let first = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        await first.signInWithCloud(callbackScheme: "mero-sample")
        XCTAssertTrue(first.isAuthenticated)

        let second = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        let restored = await second.restoreCloudSession()
        XCTAssertTrue(restored)
        XCTAssertTrue(second.isAuthenticated)
        XCTAssertEqual(second.account, first.account)
    }
}
