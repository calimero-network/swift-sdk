import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// A scripted Cloud manager + relay behind ``MockURLProtocol``: answers by
/// `METHOD path`, records every request (with headers), and lets a test swap a
/// route's answer mid-flight.
final class CloudRig: @unchecked Sendable {
    struct Seen {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        var json: JSONValue? { try? MeroJSON.decode(JSONValue.self, from: body) }
    }

    typealias Route = @Sendable (Seen) -> MockURLProtocol.Stub
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var _seen: [Seen] = []

    var seen: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return _seen
    }

    func requests(_ method: String, _ path: String) -> [Seen] {
        seen.filter { $0.method == method && $0.url.path == path }
    }

    func on(_ method: String, _ path: String, _ route: @escaping Route) {
        lock.lock(); routes["\(method) \(path)"] = route; lock.unlock()
    }

    func on(_ method: String, _ path: String, status: Int = 200, json: String) {
        on(method, path) { _ in Self.stub(status, json) }
    }

    static func stub(_ status: Int, _ json: String) -> MockURLProtocol.Stub {
        .init(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    func install() {
        MockURLProtocol.setHandler { [weak self] req in
            guard let self else { return .init(status: 500, headers: [:], body: Data()) }
            var headers: [String: String] = [:]
            for (k, v) in req.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
            let seen = Seen(
                method: req.httpMethod ?? "GET", url: req.url!, headers: headers, body: FakeNode.body(req))
            self.lock.lock()
            self._seen.append(seen)
            let route = self.routes["\(seen.method) \(seen.url.path)"]
            self.lock.unlock()
            return route?(seen) ?? Self.stub(404, #"{"error":"no route \#(seen.method) \#(seen.url.path)"}"#)
        }
    }
}

/// A wallet in a test: a root that certifies whatever device key it is shown.
struct TestWallet {
    let rootSeed = Data(repeating: 0x5C, count: 32)

    var account: String {
        try! DeviceCertificates.account(forRootPublicKey: Hex.encode(try! Ed25519.publicKey(seed: rootSeed)))
    }

    func approve(_ keys: DeviceKeys, state: String?) -> EnrolmentCallback {
        let device = try! DeviceCertificates.mintDeviceId(account: account, nonce: Data(repeating: 0xA1, count: 16))
        let credential = try! DeviceCertificates.certify(
            rootSeed: rootSeed, device: device, signPublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey)
        return EnrolmentCallback(credential: credential, account: account, device: device, state: state)
    }

    func callbackURL(_ cb: EnrolmentCallback, base: String = "mero-sample://enrol") -> URL {
        var fragment = "credential=\(cb.credential)&account=\(cb.account)&device=\(cb.device)"
        if let state = cb.state { fragment += "&state=\(state)" }
        return URL(string: "\(base)#\(fragment)")!
    }
}

final class CloudSignInTests: XCTestCase {
    private var rig: CloudRig!
    private let relay = "https://relay.test"
    private let cloud = URL(string: "https://cloud.test")!
    private let wallet = TestWallet()
    private let keys = try! DeviceKeys(
        signSecret: Data(repeating: 0x07, count: 32), kemSecret: Data(repeating: 0x08, count: 32))
    private let nodeSeed = Data(repeating: 0x42, count: 32)

    override func setUp() {
        super.setUp()
        rig = CloudRig()
        rig.install()
        MethodKinds.shared.clear()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        rig = nil
        super.tearDown()
    }

    private func rep(_ byte: String, _ count: Int = 32) -> String { String(repeating: byte, count: count) }

    // MARK: - Enrolment URL and callback

    func testEnrolmentURLCarriesKeysCallbackAndState() throws {
        let url = try DeviceEnrolment.url(
            devicePublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey,
            callbackURL: "mero-sample://enrol", state: "abc123")
        XCTAssertEqual(url.host, "wallet.cloud.calimero.network")
        XCTAssertEqual(url.path, "/account-enroll")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("enrol-device=\(keys.signPublicKey)"))
        XCTAssertTrue(query.contains("enrol-kem=\(keys.kemPublicKey)"))
        // URLSearchParams spelling: ':' and '/' are escaped.
        XCTAssertTrue(query.contains("callback-url=mero-sample%3A%2F%2Fenrol"))
        XCTAssertTrue(query.hasSuffix("state=abc123"))
    }

    func testEnrolmentAcceptsHttpsAndAppSchemesButRefusesScriptAndFragments() throws {
        for ok in ["https://app.example/calimero/enrol", "mero-sample://enrol", "com.example.app:/cb"] {
            XCTAssertNoThrow(
                try DeviceEnrolment.url(
                    devicePublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey, callbackURL: ok, state: nil))
        }
        for bad in ["javascript:alert(1)", "data:text/html,x", "https://a.example/#x", "not a url"] {
            XCTAssertThrowsError(
                try DeviceEnrolment.url(
                    devicePublicKey: keys.signPublicKey, kemPublicKey: keys.kemPublicKey, callbackURL: bad,
                    state: nil), bad)
        }
        XCTAssertThrowsError(
            try DeviceEnrolment.url(
                devicePublicKey: keys.signPublicKey.uppercased(), kemPublicKey: keys.kemPublicKey,
                callbackURL: "mero-sample://enrol", state: nil))
    }

    func testReadsTheCallbackFragmentAndRefusesADecline() throws {
        let cb = wallet.approve(keys, state: "s1")
        XCTAssertEqual(try DeviceEnrolment.readCallback(wallet.callbackURL(cb)), cb)
        XCTAssertEqual(
            try DeviceEnrolment.readCallback(wallet.callbackURL(cb, base: "https://app.example/cb")), cb)
        XCTAssertNil(try DeviceEnrolment.readCallback(URL(string: "mero-sample://enrol")!))
        XCTAssertThrowsError(try DeviceEnrolment.readCallback(URL(string: "mero-sample://enrol#error=cancelled")!)) {
            XCTAssertEqual($0 as? AccountError, .enrolmentDeclined("The device was not approved at the wallet."))
        }
    }

    func testCompleteEnrolmentChecksStateKeysAndReportedIds() throws {
        let cb = wallet.approve(keys, state: "s1")
        let enrolled = try DeviceEnrolment.completeEnrolment(cb, keys: keys, expectState: "s1")
        XCTAssertEqual(enrolled.account, wallet.account)
        XCTAssertEqual(enrolled.certificate.signPublicKey, keys.signPublicKey)

        XCTAssertThrowsError(try DeviceEnrolment.completeEnrolment(cb, keys: keys, expectState: "other")) {
            XCTAssertEqual($0 as? AccountError, .stateMismatch)
        }
        let otherKeys = DeviceKeys.generate()
        XCTAssertThrowsError(try DeviceEnrolment.completeEnrolment(cb, keys: otherKeys, expectState: "s1")) {
            XCTAssertTrue($0.localizedDescription.contains("this app holds"))
        }
        let lying = EnrolmentCallback(credential: cb.credential, account: rep("11"), device: cb.device, state: "s1")
        XCTAssertThrowsError(try DeviceEnrolment.completeEnrolment(lying, keys: keys, expectState: "s1")) {
            XCTAssertTrue($0.localizedDescription.contains("the wallet reported account"))
        }
    }

    // MARK: - Cloud manager

    func testAccountRelaysSendsTheRoutingProof() async throws {
        let cb = wallet.approve(keys, state: nil)
        rig.on(
            "GET", "/api/cloud/accounts/\(cb.account)/challenge",
            json: #"{"account_id":"\#(cb.account)","nonce":"sealed-nonce","expires_at_ms":1800000000000}"#)
        rig.on(
            "GET", "/api/cloud/accounts/\(cb.account)/relays",
            json: """
                {"account_id":"\(cb.account)","relays":[
                 {"peer_id":"p1","relay_url":null,"fresh":true,"executor_account":null,"assigned":false},
                 {"peer_id":"p2","relay_url":"https://relay.test","fresh":true,"executor_account":"\(rep("ee"))","assigned":true},
                 {"peer_id":"p3","relay_url":"https://x","fresh":false,"executor_account":"NOT-HEX","assigned":false}]}
                """)
        let client = CloudClient(
            baseURL: cloud,
            routingCredential: RoutingCredential(credential: cb.credential, deviceSecret: keys.signSecret),
            session: MockURLProtocol.makeSession())

        let relays = try await client.getAccountRelays(cb.account)
        XCTAssertEqual(relays.count, 3)
        XCTAssertNil(relays[0].relayUrl)
        XCTAssertEqual(relays[1].executorAccount, rep("ee"))
        XCTAssertTrue(relays[1].assigned)
        XCTAssertNil(relays[2].executorAccount, "a malformed executor is no executor")

        let read = try XCTUnwrap(rig.requests("GET", "/api/cloud/accounts/\(cb.account)/relays").first)
        XCTAssertEqual(read.headers["x-calimero-credential"], cb.credential)
        XCTAssertEqual(read.headers["x-calimero-nonce"], "sealed-nonce")
        XCTAssertNil(read.headers["authorization"])
        let signature = try XCTUnwrap(Data(base64Encoded: read.headers["x-calimero-signature"] ?? ""))
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: try Hex.decode(keys.signPublicKey, label: "pk", bytes: 32), signature: signature,
                message: Data("calimero.mdma.routing-read.v1\u{0}sealed-nonce".utf8)))

        let choice = CloudClient.chooseRelay(relays)
        XCTAssertEqual(choice.relayUrl, "https://relay.test")
        XCTAssertEqual(choice.executorAccount, rep("ee"))
        XCTAssertNil(choice.note)
    }

    func testAccountRelaysRefusesWithoutACredential() async {
        do {
            _ = try await CloudClient(baseURL: cloud, session: MockURLProtocol.makeSession()).getAccountRelays(
                rep("11"))
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(rig.seen.isEmpty, "nothing is sent without a credential")
        }
    }

    func testChooseRelayPrefersFreshThenStaleThenNone() {
        func relay(_ url: String?, fresh: Bool) -> CloudAccountRelay {
            CloudAccountRelay(peerId: "p", relayUrl: url, fresh: fresh, executorAccount: nil, assigned: false)
        }
        XCTAssertEqual(
            CloudClient.chooseRelay([relay("https://stale", fresh: false), relay("https://fresh", fresh: true)])
                .relayUrl, "https://fresh")
        let stale = CloudClient.chooseRelay([relay(nil, fresh: true), relay("https://stale", fresh: false)])
        XCTAssertEqual(stale.relayUrl, "https://stale")
        XCTAssertNotNil(stale.note)
        let none = CloudClient.chooseRelay([relay(nil, fresh: true)])
        XCTAssertNil(none.relayUrl)
        XCTAssertNotNil(none.note)
        XCTAssertNil(CloudClient.chooseRelay([]).relayUrl)
    }

    func testNamespaceRoutingIsProvenWhenACredentialIsConfigured() async throws {
        let ns = rep("aa")
        rig.on("GET", "/api/cloud/namespaces/\(ns)/challenge", json: #"{"namespace_id":"\#(ns)","nonce":"n2"}"#)
        rig.on(
            "GET", "/api/cloud/namespaces/\(ns)/admitters",
            json: """
                {"namespace_id":"\(ns)","servable":true,"writable":true,"admitters":[
                 {"peer_id":"p","account":"\(rep("bb"))","relay_url":"https://relay.test","admit_url":null,
                  "status":"active","fresh":true,"can_admit":true,"authorship_ready":true,"tee_role":"RelayTee"}]}
                """)
        let cb = wallet.approve(keys, state: nil)
        let client = CloudClient(
            baseURL: cloud,
            routingCredential: RoutingCredential(credential: cb.credential, deviceSecret: keys.signSecret),
            session: MockURLProtocol.makeSession())
        let routing = try await client.getNamespaceRouting(ns)
        XCTAssertTrue(routing.servable)
        XCTAssertEqual(routing.nodes.first?.teeRole, "RelayTee")
        XCTAssertEqual(routing.nodes.first?.canExecute, true, "legacy grant-based answer without can_execute")
        XCTAssertEqual(
            rig.requests("GET", "/api/cloud/namespaces/\(ns)/admitters").first?.headers["x-calimero-nonce"], "n2")
        let admitter = try await client.findAdmitter(ns, admitters: [rep("cc")])
        XCTAssertNil(admitter, "a node the invitation does not name is not an admitter")
    }

    // MARK: - Relay node key + login

    private func serveRelayLogin(boundKey: String? = nil, bindNonce: Bool = true) {
        let nodeKey = try! Ed25519.publicKey(seed: nodeSeed)
        rig.on("POST", "/admin-api/tee/attest") { seen in
            let nonceHex = seen.json?["nonce"]?.stringValue ?? ""
            let nonce =
                bindNonce ? (try? Hex.decode(nonceHex, label: "n", bytes: 32)) ?? Data(count: 32) : Data(count: 32)
            let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(nodeKey)
            return CloudRig.stub(
                200,
                #"{"data":{"quoteB64":"\#(quote.base64EncodedString())","boundPublicKey":"\#(boundKey ?? Hex.encode(nodeKey))"}}"#
            )
        }
        rig.on("GET", "/auth/challenge", json: #"{"data":{"challenge":"\#(String(repeating: "c4", count: 32))"}}"#)
        rig.on(
            "POST", "/auth/token",
            json: #"{"data":{"access_token":"relay-access","refresh_token":"relay-refresh"}}"#)
    }

    func testRelayLoginSignsTheStatementForTheAttestedKey() async throws {
        serveRelayLogin()
        let session = MockURLProtocol.makeSession()
        let nodeKey = try await RelayNodeKey.attest(
            relayURL: relay, verifier: TLSRelayKeyVerifier(allowMock: true), session: session)
        XCTAssertEqual(nodeKey, Hex.encode(try Ed25519.publicKey(seed: nodeSeed)))
        let attest = try XCTUnwrap(rig.requests("POST", "/admin-api/tee/attest").first?.json)
        XCTAssertEqual(attest["bindNodeKey"], true)
        XCTAssertEqual(attest["includeCollateral"], true)

        let cb = wallet.approve(keys, state: nil)
        let tokens = try await RelayLogin.login(
            relayURL: relay, nodeKey: nodeKey, credential: cb.credential, keys: keys,
            audience: .codeSigningId("network.calimero.test"), session: session)
        XCTAssertEqual(tokens.accessToken, "relay-access")
        XCTAssertEqual(tokens.refreshToken, "relay-refresh")

        let body = try XCTUnwrap(rig.requests("POST", "/auth/token").first?.json)
        XCTAssertEqual(body["auth_method"], "account_proof")
        let provider = try XCTUnwrap(body["provider_data"])
        XCTAssertEqual(provider["account_proof"]?.stringValue, cb.credential)
        XCTAssertEqual(provider["challenge"]?.stringValue, String(repeating: "c4", count: 32))
        // The statement names the attested node, this device, and the session key sent.
        let statement = try Hex.decodeUnsized(provider["login_statement"]?.stringValue ?? "", label: "s")
        XCTAssertEqual(Hex.encode(statement.prefix(32)), nodeKey)
        let sessionKey = try XCTUnwrap(body["public_key"]?.stringValue)
        let audienceLen = 1 + 4 + "network.calimero.test".utf8.count
        XCTAssertEqual(Hex.encode(statement.dropFirst(32 + audienceLen + 32).prefix(32)), sessionKey)
        XCTAssertEqual(Hex.encode(statement.dropFirst(32 + audienceLen + 64).prefix(32)), keys.signPublicKey)
    }

    func testVerifierRefusesUnboundOrMockQuotesFromHostedRelays() async {
        serveRelayLogin(bindNonce: false)
        let session = MockURLProtocol.makeSession()
        do {
            _ = try await RelayNodeKey.attest(
                relayURL: relay, verifier: TLSRelayKeyVerifier(allowMock: true), session: session)
            XCTFail("a quote not carrying our nonce must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nonce"))
        }
        serveRelayLogin()
        do {
            _ = try await RelayNodeKey.attest(relayURL: relay, session: session)
            XCTFail("a mock quote from a hosted relay must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("MOCK"))
        }
        serveRelayLogin(boundKey: rep("99"))
        do {
            _ = try await RelayNodeKey.attest(
                relayURL: relay, verifier: TLSRelayKeyVerifier(allowMock: true), session: session)
            XCTFail("a quote binding another key must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("bind"))
        }
    }

    // MARK: - Relay client

    private func makeRelay(
        nonces: any WarrantNonceStore = MemoryWarrantNonceStore(), token: String? = nil
    ) -> RelayClient {
        let cb = wallet.approve(keys, state: nil)
        return RelayClient(
            relayURL: relay + "/", authorAccount: cb.account, authorProof: cb.credential, keys: keys, nonces: nonces,
            tokenProvider: { token }, session: MockURLProtocol.makeSession())
    }

    private func serveDescribe(_ ctx: String) {
        rig.on(
            "GET", "/admin-api/contexts/\(ctx)/intents",
            json: """
                {"data":{"executorAccount":"\(rep("33"))","executorKey":"\(rep("77"))","canAuthorOnBehalf":true,
                 "groupId":"\(rep("99"))","releaseBytecodeId":"\(rep("44"))","releaseVersion":"1.0.0"}}
                """)
    }

    func testExecuteSendsAWarrantThatVerifies() async throws {
        let ctx = rep("11")
        serveDescribe(ctx)
        rig.on("POST", "/admin-api/contexts/\(ctx)/intents", json: #"{"data":{"rootHash":"rh","returns":{"ok":1}}}"#)
        let client = makeRelay()

        let result = try await client.execute(contextId: ctx, method: "set", argsJson: ["value": "v", "key": "k"])
        XCTAssertEqual(result.rootHash, "rh")
        XCTAssertEqual(result.returns, ["ok": 1])

        let sent = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").first)
        XCTAssertNil(sent.headers["authorization"], "a warrant needs no token")
        // The body is canonical, so the args hashed are the args sent.
        let text = String(decoding: sent.body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""argsJson":{"key":"k","value":"v"}"#), text)
        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(body["method"], "set")
        XCTAssertEqual(body["authorProof"]?.stringValue, client.authorProof)

        let warrant = try XCTUnwrap(body["warrant"]?.stringValue)
        let input = Warrants.WarrantInput(
            context: ctx, authorAccount: client.authorAccount, executor: rep("33"), executorKey: rep("77"),
            releaseBytecodeId: rep("44"), releaseVersion: "1.0.0", method: "set",
            argsJson: ["key": "k", "value": "v"], nonce: 1,
            notAfter: UInt64(
                try Hex.decode(String(warrant.dropLast(128).suffix(16)), label: "na", bytes: 8)
                    .withUnsafeBytes { $0.load(as: UInt64.self) }))
        let pk = try Hex.decode(keys.signPublicKey, label: "pk", bytes: 32)
        let preimage = try Warrants.warrantPreimage(input, devicePublicKey: pk)
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: pk, signature: try Hex.decode(String(warrant.suffix(128)), label: "sig", bytes: 64),
                message: preimage))
        // nonce 1 is the first of the sequence.
        XCTAssertEqual(String(warrant.dropLast(128 + 16).suffix(16)), "0100000000000000")
    }

    func testNonceRefusalRecoversFromTheNodesRecordAndRetriesOnce() async throws {
        let ctx = rep("11")
        serveDescribe(ctx)
        let attempts = Counter()
        rig.on("POST", "/admin-api/contexts/\(ctx)/intents") { _ in
            attempts.increment() == 1
                ? CloudRig.stub(403, #"{"error":"warrant nonce 1 already spent"}"#)
                : CloudRig.stub(200, #"{"data":{"rootHash":"rh2","returns":null}}"#)
        }
        rig.on(
            "POST", "/admin-api/contexts/\(ctx)/warrant-nonce",
            json:
                #"{"data":{"contextId":"c","authorDeviceKey":"d","seen":true,"#
                + #""highWaterNonce":9007199254740993,"nextNonce":9007199254740994,"windowWidth":64}}"#
        )
        let nonces = MemoryWarrantNonceStore()
        let client = makeRelay(nonces: nonces, token: "relay-access")

        let result = try await client.execute(contextId: ctx, method: "set")
        XCTAssertEqual(result.rootHash, "rh2")
        XCTAssertNil(result.returns)
        XCTAssertEqual(attempts.count, 2)
        let lookup = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(ctx)/warrant-nonce").first)
        XCTAssertEqual(lookup.headers["authorization"], "Bearer relay-access")
        XCTAssertEqual(lookup.json?["authorProof"]?.stringValue, client.authorProof)
        // Read from the digits, not a Double: 2^53 + 2 survives exactly.
        let retried = try XCTUnwrap(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").last?.json)
        let warrant = try XCTUnwrap(retried["warrant"]?.stringValue)
        let nonceLE = try Hex.decode(String(warrant.dropLast(128 + 16).suffix(16)), label: "n", bytes: 8)
        XCTAssertEqual(nonceLE.withUnsafeBytes { $0.load(as: UInt64.self) }, 9_007_199_254_740_994)
        XCTAssertEqual(nonces.next(relay: relay), 9_007_199_254_740_995)
    }

    func testNonRetryableRefusalIsSurfaced() async {
        let ctx = rep("11")
        serveDescribe(ctx)
        rig.on("POST", "/admin-api/contexts/\(ctx)/intents", status: 403, json: #"{"error":"not a member"}"#)
        do {
            _ = try await makeRelay().execute(contextId: ctx, method: "set")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(
                error as? AccountError, .intentRefused(reason: "not a member", retryable: false, status: 403))
        }
    }

    func testQueryReadsBySessionAndFallsBackToAWarrantOn409() async throws {
        let ctx = rep("11")
        serveDescribe(ctx)
        rig.on("POST", "/admin-api/contexts/\(ctx)/query") { seen in
            seen.json?["method"] == "get_messages"
                ? CloudRig.stub(200, #"{"data":{"returns":[1,2]}}"#)
                : CloudRig.stub(409, #"{"error":"not a view"}"#)
        }
        rig.on("POST", "/admin-api/contexts/\(ctx)/intents", json: #"{"data":{"rootHash":"rh","returns":"w"}}"#)
        let client = makeRelay(token: "relay-access")

        let read = try await client.query(contextId: ctx, method: "get_messages")
        XCTAssertEqual(read, [1, 2])
        XCTAssertEqual(
            rig.requests("POST", "/admin-api/contexts/\(ctx)/query").first?.headers["authorization"],
            "Bearer relay-access")
        XCTAssertTrue(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").isEmpty)

        let write = try await client.query(contextId: ctx, method: "send_message")
        XCTAssertEqual(write, "w")
        // Learned: the next call skips the probe.
        _ = try await client.query(contextId: ctx, method: "send_message")
        XCTAssertEqual(rig.requests("POST", "/admin-api/contexts/\(ctx)/query").count, 2)
        XCTAssertEqual(rig.requests("POST", "/admin-api/contexts/\(ctx)/intents").count, 2)
    }

    func testCreateContextChecksStandingBeforeSpendingANonce() async throws {
        let group = rep("99")
        rig.on(
            "GET", "/admin-api/groups/\(group)/context-intents",
            json:
                #"{"data":{"executorAccount":"\#(rep("33"))","executorKey":"\#(rep("77"))","#
                + #""groupId":"\#(group)","canCreateOnBehalf":false}}"#
        )
        let nonces = MemoryWarrantNonceStore()
        let client = makeRelay(nonces: nonces)
        do {
            _ = try await client.createContext(groupId: group, applicationId: rep("44"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no nonce was spent"))
        }
        XCTAssertEqual(nonces.next(relay: relay), 1, "nothing was spent")
        XCTAssertEqual(
            rig.requests("GET", "/admin-api/groups/\(group)/context-intents").first?.url.query,
            "author=\(client.authorAccount)")

        rig.on(
            "GET", "/admin-api/groups/\(group)/context-intents",
            json:
                #"{"data":{"executorAccount":"\#(rep("33"))","executorKey":"\#(rep("77"))","#
                + #""groupId":"\#(group)","canCreateOnBehalf":true,"authorMayCreate":true}}"#
        )
        rig.on(
            "POST", "/admin-api/groups/\(group)/context-intents",
            json: #"{"data":{"contextId":"ctx-new","groupId":"\#(group)","memberPublicKey":"mpk"}}"#)
        let created = try await client.createContext(
            groupId: group, applicationId: rep("44"), initArgs: ["name": "general"], name: "general")
        XCTAssertEqual(created.contextId, "ctx-new")
        let body = try XCTUnwrap(rig.requests("POST", "/admin-api/groups/\(group)/context-intents").first?.json)
        XCTAssertEqual(body["initArgs"], ["name": "general"])
        XCTAssertEqual(body["warrant"]?.stringValue?.count, (421 - 64) * 2, "the fixture minus its two cited heads")
    }

    func testGovernSendsTheOpHexWithAGovernanceWarrant() async throws {
        let group = rep("99")
        rig.on(
            "GET", "/admin-api/groups/\(group)/governance-intents",
            json:
                #"{"data":{"executorAccount":"\#(rep("33"))","executorKey":"\#(rep("77"))","groupId":"\#(group)","canActOnBehalf":true}}"#
        )
        rig.on("POST", "/admin-api/groups/\(group)/governance-intents", json: #"{"data":{"groupId":"\#(group)"}}"#)
        let returned = try await makeRelay().govern(
            groupId: group, op: Warrants.GovernanceOp(kind: .group, bytes: Data([9, 8, 7])))
        XCTAssertEqual(returned, group)
        let body = try XCTUnwrap(rig.requests("POST", "/admin-api/groups/\(group)/governance-intents").first?.json)
        XCTAssertEqual(body["op"], "090807")
        XCTAssertEqual(body["warrant"]?.stringValue?.count, (345 - 64) * 2, "the fixture minus its two cited heads")
    }

    // MARK: - Join

    private func invitation(expires: Int = 1_900_000_000, admitters: [String] = []) -> SignedGroupOpenInvitation {
        SignedGroupOpenInvitation(
            invitation: GroupInvitationFromAdmin(
                inviterIdentity: Array(repeating: 1, count: 32), groupId: Array(repeating: 2, count: 32),
                expirationTimestamp: expires, secretSalt: Array(repeating: 3, count: 32), invitedRole: 1,
                admitters: admitters),
            inviterSignature: "deadbeef")
    }

    func testEncodeSignedInvitationWritesAdmitterAddrsAsBareStrings() throws {
        var one = invitation()
        let without = try NamespaceOps.encodeSignedInvitation(one)
        let addr = "/ip4/10.0.0.1/tcp/2528/p2p/12D3KooWExample"
        one.admitterAddrs = [addr]
        let with = try NamespaceOps.encodeSignedInvitation(one)
        XCTAssertEqual(with.count - without.count, 4 + addr.utf8.count)
        // inviter(32) group(32) exp(8) salt(32) role(1) admitters(4) sig("deadbeef") inviter_account(0)
        XCTAssertEqual(without.count, 32 + 32 + 8 + 32 + 1 + 4 + 4 + 8 + 1 + 4 + 1 + 1)
    }

    func testMemberJoinOpLayoutAndSignature() throws {
        let cb = wallet.approve(keys, state: nil)
        let ns = rep("aa")
        let op = try NamespaceOps.signMemberJoinOp(
            namespaceId: ns, member: cb.account, invitation: invitation(), credential: cb.credential, keys: keys,
            nonce: 5, joinedAt: 1_700_000_000)
        let bytes = try Hex.decodeUnsized(op, label: "op")
        XCTAssertEqual(bytes.first, 24, "schema 24")
        XCTAssertEqual(Hex.encode(bytes.dropFirst(1).prefix(32)), ns)
        XCTAssertEqual(Hex.encode(bytes.dropFirst(33).prefix(4)), "00000000", "no parents")
        XCTAssertEqual(Hex.encode(bytes.dropFirst(37).prefix(32)), keys.signPublicKey)
        XCTAssertEqual(Hex.encode(bytes.dropFirst(69).prefix(8)), "0500000000000000")
        XCTAssertEqual(bytes[77], 0, "root op")
        XCTAssertEqual(bytes[78], 8, "MemberJoinedAt for an expiring invitation")
        XCTAssertEqual(bytes.last, 0, "unendorsed")
        let signable = bytes.dropLast(65)
        XCTAssertTrue(Hex.encode(signable).hasSuffix(cb.credential))
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: try Hex.decode(keys.signPublicKey, label: "pk", bytes: 32),
                signature: Data(bytes.dropLast().suffix(64)),
                message: Data("calimero.namespace.v1".utf8) + signable))

        let open = try Hex.decodeUnsized(
            NamespaceOps.signMemberJoinOp(
                namespaceId: ns, member: cb.account, invitation: invitation(expires: 0), credential: cb.credential,
                keys: keys, nonce: 5),
            label: "op")
        XCTAssertEqual(open[78], 5, "MemberJoined for a non-expiring invitation")
        XCTAssertEqual(bytes.count - open.count, 8, "joined_at is only in the expiring form")
    }

    // MARK: - End to end

    private func makeSignIn(
        nonces: any WarrantNonceStore = MemoryWarrantNonceStore()
    ) -> (
        CloudSignIn, AnyValueStore<CloudSession>
    ) {
        let sessions = AnyValueStore<CloudSession>.memory()
        let signIn = CloudSignIn(
            config: CloudConfig(
                cloudBaseURL: cloud, audience: .codeSigningId("network.calimero.test"),
                relayKeyVerifier: TLSRelayKeyVerifier(allowMock: true)),
            keyStore: .memory(keys), sessionStore: sessions, nonces: nonces, urlSession: MockURLProtocol.makeSession())
        return (signIn, sessions)
    }

    func testSignInEnrolsFindsTheRelayAndLogsIn() async throws {
        let (signIn, sessions) = makeSignIn()
        let walletURL = try await signIn.beginEnrolment(callbackURL: "mero-sample://enrol")
        let state = try XCTUnwrap(
            URLComponents(url: walletURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?
                .value)
        let cb = wallet.approve(keys, state: state)
        rig.on("GET", "/api/cloud/accounts/\(cb.account)/challenge", json: #"{"nonce":"n"}"#)
        rig.on(
            "GET", "/api/cloud/accounts/\(cb.account)/relays",
            json:
                #"{"relays":[{"peer_id":"p","relay_url":"\#(relay)","fresh":true,"executor_account":"\#(rep("33"))","assigned":true}]}"#
        )
        serveRelayLogin()

        let session = try await signIn.completeEnrolment(callbackURL: wallet.callbackURL(cb))
        XCTAssertEqual(session.account, wallet.account)
        XCTAssertEqual(session.relayUrl, relay)
        XCTAssertEqual(session.executorAccount, rep("33"))
        XCTAssertEqual(sessions.load(), session, "persisted")

        let connection = await signIn.connect(session)
        XCTAssertNil(connection.readNote)
        XCTAssertNotNil(connection.relay)
        let mero = try XCTUnwrap(connection.mero)
        let token = await mero.currentTokenData()?.accessToken
        XCTAssertEqual(token, "relay-access")

        // Sign out retires the refresh token and forgets the session.
        rig.on("POST", "/auth/logout", json: #"{"data":{"success":true}}"#)
        await signIn.signOut()
        XCTAssertNil(sessions.load())
        let logout = try XCTUnwrap(rig.requests("POST", "/auth/logout").first?.json)
        XCTAssertEqual(logout, ["refresh_token": "relay-refresh"])
    }

    func testAForeignCallbackIsRefusedAndNothingIsStored() async throws {
        let (signIn, sessions) = makeSignIn()
        _ = try await signIn.beginEnrolment(callbackURL: "mero-sample://enrol")
        let cb = wallet.approve(keys, state: "not-the-one-sent")
        do {
            _ = try await signIn.completeEnrolment(callbackURL: wallet.callbackURL(cb))
            XCTFail("expected a state mismatch")
        } catch {
            XCTAssertEqual(error as? AccountError, .stateMismatch)
        }
        XCTAssertNil(sessions.load())
        XCTAssertTrue(rig.seen.isEmpty)
    }

    func testRelaylessAccountIsStillSignedIn() async throws {
        let (signIn, _) = makeSignIn()
        let url = try await signIn.beginEnrolment(callbackURL: "https://app.example/cb")
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?
            .value
        let cb = wallet.approve(keys, state: state)
        rig.on("GET", "/api/cloud/accounts/\(cb.account)/challenge", json: #"{"nonce":"n"}"#)
        rig.on("GET", "/api/cloud/accounts/\(cb.account)/relays", json: #"{"relays":[]}"#)
        let session = try await signIn.completeEnrolment(
            callbackURL: wallet.callbackURL(cb, base: "https://app.example/cb"))
        XCTAssertTrue(session.isRelayless)
        XCTAssertNotNil(session.note)
        let connection = await signIn.connect(session)
        XCTAssertNil(connection.relay)
        XCTAssertNil(connection.mero)
    }

    func testConnectKeepsWritesWhenTheRelayWillNotAttest() async throws {
        let (signIn, _) = makeSignIn()
        rig.on("POST", "/admin-api/tee/attest", status: 503, json: #"{"error":"down"}"#)
        let cb = wallet.approve(keys, state: nil)
        let connection = await signIn.connect(
            CloudSession(account: cb.account, device: cb.device, credential: cb.credential, relayUrl: relay))
        XCTAssertNotNil(connection.relay, "writes need no node key")
        XCTAssertNil(connection.mero)
        XCTAssertNotNil(connection.readNote)
    }

    func testJoinAdmitsThroughTheInvitedRelayAndAdoptsIt() async throws {
        let (signIn, sessions) = makeSignIn()
        let cb = wallet.approve(keys, state: nil)
        sessions.save(CloudSession(account: cb.account, device: cb.device, credential: cb.credential))
        let ns = rep("aa")
        rig.on("GET", "/api/cloud/namespaces/\(ns)/challenge", json: #"{"nonce":"n"}"#)
        rig.on(
            "GET", "/api/cloud/namespaces/\(ns)/admitters",
            json: """
                {"servable":true,"admitters":[
                 {"peer_id":"p","account":"\(rep("bb"))","relay_url":"\(relay)","status":"active","fresh":true,
                  "can_admit":true,"authorship_ready":true,"can_execute":true}]}
                """)
        rig.on("POST", "/admin-api/namespaces/\(ns)/admit", json: #"{"data":{"published":true}}"#)

        let (session, outcome) = try await signIn.join(namespaceId: ns, invitation: invitation(admitters: [rep("bb")]))
        XCTAssertTrue(outcome.published)
        XCTAssertEqual(outcome.relay?.admitterAccount, rep("bb"))
        XCTAssertEqual(session.relayUrl, relay)
        let admit = try XCTUnwrap(rig.requests("POST", "/admin-api/namespaces/\(ns)/admit").first?.json)
        XCTAssertNotNil(admit["invitation"]?["invitation"])
        XCTAssertEqual(admit["signedOp"]?.stringValue?.prefix(2), "18")
    }
}
