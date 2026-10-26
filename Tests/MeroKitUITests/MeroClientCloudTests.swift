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

/// The relay the stubbed Cloud manager names, changeable mid-test. `""` lists no
/// relay at all (a new account); ``RelayAnswer/fail`` answers the lookup with a 503.
private final class RelayAnswer: @unchecked Sendable {
    static let fail = "FAIL"
    private let lock = NSLock()
    private var url = "https://relay.test"
    var value: String {
        get { lock.withLock { url } }
        set { lock.withLock { url = newValue } }
    }
}

@MainActor
final class MeroClientCloudTests: XCTestCase {
    private let relay = "https://relay.test"
    private let relayAnswer = RelayAnswer()

    override func setUp() {
        super.setUp()
        let relayAnswer = self.relayAnswer
        MockURLProtocol.setHandler { req in
            let path = req.url?.path ?? ""
            func json(_ s: String) -> MockURLProtocol.Stub {
                .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
            }
            if path.hasSuffix("/challenge"), path.hasPrefix("/api/cloud/") { return json(#"{"nonce":"n"}"#) }
            if path.hasSuffix("/relays") {
                switch relayAnswer.value {
                case RelayAnswer.fail: return .init(status: 503, headers: [:], body: Data())
                case "": return json(#"{"relays":[]}"#)
                default:
                    return json(#"{"relays":[{"peer_id":"p","relay_url":"\#(relayAnswer.value)","fresh":true}]}"#)
                }
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
            config: CloudConfig(relayKeyVerifier: DcapRelayKeyVerifier(allowMock: true), sealRelays: false),
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

    func testLogoutKeepsTheDeviceUnlessToldToForgetIt() async {
        let session = MockURLProtocol.makeSession()
        let keys = AnyValueStore<DeviceKeys>.memory()
        let nonces = MemoryWarrantNonceStore()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true), sealRelays: false),
            keyStore: keys, sessionStore: .memory(), nonces: nonces, urlSession: session, delegatedStore: .memory())
        let client = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())

        await client.signInWithCloud(callbackScheme: "mero-sample")
        let device = keys.load()
        XCTAssertNotNil(device)
        _ = nonces.next(relay: relay)
        await client.logout()
        XCTAssertEqual(keys.load(), device, "a plain logout keeps the device key")
        XCTAssertEqual(nonces.next(relay: relay), 2)

        await client.signInWithCloud(callbackScheme: "mero-sample")
        XCTAssertTrue(client.isAuthenticated)
        await client.logout(forgetDevice: true)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(keys.load(), "forgetDevice drops the key certified to the old account")
        XCTAssertEqual(nonces.next(relay: relay), 1, "and the nonces spent under it")
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

    /// SEC-01: a wallet answer for this device's keys that this app never asked
    /// for (someone else's passkey, sent as a link) signs nobody in.
    func testAnUnsolicitedEnrolmentLinkIsRefused() async throws {
        let session = MockURLProtocol.makeSession()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true), sealRelays: false),
            keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore(), urlSession: session)
        let client = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        let keys = await cloud.deviceKeys()
        let walletURL = try DeviceEnrolment.url(
            devicePublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey, callbackURL: "mero-sample://enrol",
            state: "attacker-chosen")
        let link = try await InProcessWallet().authenticate(url: walletURL, callback: .scheme("mero-sample"))

        let handled = await client.handleEnrolmentCallback(link)
        XCTAssertTrue(handled)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(client.errorMessage, "That sign-in did not come from this app. Please try again.")
        let stored = await cloud.restoreSession()
        XCTAssertNil(stored)
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
            config: CloudConfig(relayKeyVerifier: DcapRelayKeyVerifier(allowMock: true), sealRelays: false),
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

    /// 2026-10-21: an HA rebuild moved the account's relay to a new VM and the
    /// persisted hostname stopped resolving. A restore asks the Cloud manager
    /// again instead of reconnecting to the dead relay forever.
    func testRestoreAsksTheCloudForTheRelayAgain() async {
        let session = MockURLProtocol.makeSession()
        let sessions = AnyValueStore<CloudSession>.memory()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: DcapRelayKeyVerifier(allowMock: true), sealRelays: false),
            keyStore: .memory(), sessionStore: sessions, nonces: MemoryWarrantNonceStore(), urlSession: session)
        let first = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        await first.signInWithCloud(callbackScheme: "mero-sample")
        XCTAssertEqual(first.relayURL, relay)

        relayAnswer.value = "https://relay2.test"
        let second = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        let restored = await second.restoreCloudSession()
        XCTAssertTrue(restored)
        XCTAssertEqual(second.relayURL, "https://relay2.test")
        XCTAssertEqual(sessions.load()?.relayUrl, "https://relay2.test", "the new relay is persisted")
    }

    /// A new account was confirmed relayless; on the next launch the lookup fails. The restored
    /// connection must not still claim the account is new: nothing vouches for that any more.
    func testARestoreWhoseLookupFailsDoesNotKeepTheNewAccountConfirmation() async {
        relayAnswer.value = ""
        let session = MockURLProtocol.makeSession()
        let sessions = AnyValueStore<CloudSession>.memory()
        let cloud = CloudSignIn(
            config: CloudConfig(relayKeyVerifier: DcapRelayKeyVerifier(allowMock: true), sealRelays: false),
            keyStore: .memory(), sessionStore: sessions, nonces: MemoryWarrantNonceStore(), urlSession: session)
        let first = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        await first.signInWithCloud(callbackScheme: "mero-sample")
        XCTAssertEqual(first.connection?.session.isConfirmedRelayless, true)

        relayAnswer.value = RelayAnswer.fail
        let second = MeroClient(session: session, cloud: cloud, webAuthenticator: InProcessWallet())
        let restored = await second.restoreCloudSession()
        XCTAssertTrue(restored)
        XCTAssertEqual(second.connection?.session.isConfirmedRelayless, false)
    }
}
