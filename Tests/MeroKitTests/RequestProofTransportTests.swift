import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The calls a test's proof callback received.
final class ProofCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ProofRequest] = []

    var requests: [ProofRequest] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func callback(returning proof: String?) -> ProofCallback {
        { [self] request in
            lock.lock(); defer { lock.unlock() }
            calls.append(request)
            return proof
        }
    }
}

/// Request proofs on the wire (port of mero-js `proof-transport.test.ts`,
/// `mero-js-proof.test.ts` and the redirect half of `sse.test.ts`): the
/// header is minted per request over what is actually sent, and a request
/// carrying it never follows a redirect.
final class RequestProofTransportTests: XCTestCase {
    private static let credential =
        "028a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c0000000004cfa21629a77f8cd8ddd3"
        + "f821ed514009a9f572b2ce8e0a11f5cbb5e25340b0222222222222222222222222222222229aeef190d5865e90861a94"
        + "ec2e0b28de17cb79fb2b4120f2b1ec65e4198d6e08b28e813feb01e4a400839b85e18080ce0909090909090909090909"
        + "0909090909090909090909090909090909090909090000000000000000bba802950e323563e8cef9867dfd562dfbd50e"
        + "106ccd07c779acf3e4daba6a964e0d1354ee521747c38e0aa9839d9460dbc5a278822ac729e58f62ed8835120f"

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func serve(status: Int = 200, headers: [String: String] = [:], body: String = "{}") -> ProofTransportLog {
        let log = ProofTransportLog()
        MockURLProtocol.setHandler { req in
            log.append(req)
            var all = ["Content-Type": "application/json"]
            all.merge(headers) { _, new in new }
            return .init(status: status, headers: all, body: Data(body.utf8))
        }
        return log
    }

    private func client(
        _ base: String = "https://relay.example", getProof: ProofCallback? = nil,
        authorize: RequestAuthorizer? = nil
    ) -> URLSessionHttpClient {
        URLSessionHttpClient(
            baseURL: URL(string: base)!, hooks: TransportHooks(getProof: getProof, authorizeRequest: authorize),
            session: MockURLProtocol.makeSession())
    }

    // MARK: - The header

    func testSendsNoProofHeaderWhenNoneIsConfigured() async throws {
        let log = serve()
        try await client().sendVoid(HttpRequest(path: "/admin-api/contexts"))
        XCTAssertNil(log.requests.first?.proof)
    }

    func testSignsTheMethodThePathAndTheBodyActuallySent() async throws {
        let log = serve()
        let calls = ProofCallLog()
        try await client(getProof: calls.callback(returning: "deadbeef")).sendVoid(
            HttpRequest(path: "/admin-api/contexts/ctx-1/intents", method: .post, body: .json(Data(#"{"a":1}"#.utf8))))
        XCTAssertEqual(
            calls.requests,
            [ProofRequest(method: "POST", path: "/admin-api/contexts/ctx-1/intents", body: Data(#"{"a":1}"#.utf8))])
        XCTAssertEqual(log.requests.first?.proof, "deadbeef")
        XCTAssertEqual(log.requests.first?.body, Data(#"{"a":1}"#.utf8))
    }

    func testSignsThePathAndQueryAsTheyAreSent() async throws {
        _ = serve()
        let calls = ProofCallLog()
        try await client(getProof: calls.callback(returning: "aa")).sendVoid(
            HttpRequest(path: "/admin-api/blobs/blob-1?hash=h&context_id=a%2Fb"))
        XCTAssertEqual(calls.requests.first?.path, "/admin-api/blobs/blob-1?hash=h&context_id=a%2Fb")
    }

    func testDropsOnlyABareQuestionMarkBeforeSigningAndFetching() async throws {
        try await expectFetched("/x?", as: "/x")
        try await expectFetched("/x?q=what?", as: "/x?q=what?")
    }

    /// `requested` is fetched, and signed, as `sent`.
    private func expectFetched(_ requested: String, as sent: String) async throws {
        let log = serve()
        let calls = ProofCallLog()
        try await client(getProof: calls.callback(returning: "aa")).sendVoid(HttpRequest(path: requested))
        XCTAssertEqual(log.requests.first?.url, "https://relay.example\(sent)", requested)
        XCTAssertEqual(calls.requests.first?.path, sent, requested)
    }

    func testSignsThePrefixABaseURLContributes() async throws {
        _ = serve()
        let calls = ProofCallLog()
        try await client("https://relay.example/node-7", getProof: calls.callback(returning: "aa")).sendVoid(
            HttpRequest(path: "/admin-api/contexts"))
        XCTAssertEqual(calls.requests.first?.path, "/node-7/admin-api/contexts")
    }

    func testStillSendsTheRequestWhenTheSignerDeclines() async throws {
        let log = serve()
        let calls = ProofCallLog()
        try await client(getProof: calls.callback(returning: nil)).sendVoid(HttpRequest(path: "/admin-api/contexts"))
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertNil(log.requests.first?.proof)
    }

    func testRefusesAFileBodyItCannotCommitTo() async throws {
        let log = serve()
        let calls = ProofCallLog()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("proof-body.bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let body = HttpBody.file(file, contentType: "application/octet-stream")
            try await client(getProof: calls.callback(returning: "aa")).sendVoid(
                HttpRequest(path: "/admin-api/blobs", method: .put, body: body))
            XCTFail("a streamed body was signed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot commit to a file body"), "\(error)")
        }
        XCTAssertTrue(log.requests.isEmpty)
    }

    func testAnAuthorizerMergesItsHeaders() async throws {
        let log = serve()
        let authorized = client(authorize: { _ in ["X-Calimero-Proof": "aa"] })
        try await authorized.sendVoid(HttpRequest(path: "/admin-api/contexts"))
        XCTAssertEqual(log.requests.first?.proof, "aa")
    }

    // MARK: - Redirects

    func testAProofCarryingRedirectIsAnErrorNamingTheProofAndIsNotResent() async {
        let log = serve(status: 302, headers: ["Location": "https://elsewhere.example/x"], body: "")
        let calls = ProofCallLog()
        do {
            let signing = client(getProof: calls.callback(returning: "aa"))
            try await signing.sendVoid(HttpRequest(path: "/admin-api/contexts"))
            XCTFail("a redirect was accepted")
        } catch {
            guard case MeroError.http(let http) = error else { return XCTFail("expected .http, got \(error)") }
            XCTAssertEqual(http.status, 0)
            XCTAssertEqual(http.statusText, "Redirect Not Followed")
            XCTAssertTrue(http.bodyText?.contains("X-Calimero-Proof") == true)
        }
        XCTAssertEqual(log.requests.count, 1)
    }

    func testAnAuthorizerSignedRedirectIsRefusedTheSameWay() async {
        _ = serve(status: 307, headers: ["Location": "https://elsewhere.example/x"], body: "")
        do {
            try await client(authorize: { _ in ["X-Calimero-Proof": "aa"] }).sendVoid(HttpRequest(path: "/x"))
            XCTFail("a redirect was accepted")
        } catch {
            XCTAssertEqual((error as? MeroError)?.httpStatus, 0)
        }
    }

    func testARedirectWithoutAProofIsAPlainHTTPError() async {
        _ = serve(status: 302, headers: ["Location": "/x"], body: "")
        do {
            try await client().sendVoid(HttpRequest(path: "/admin-api/contexts"))
            XCTFail("a redirect was accepted")
        } catch {
            guard case MeroError.http(let http) = error else { return XCTFail("expected .http, got \(error)") }
            XCTAssertEqual(http.status, 302)
            XCTAssertFalse(http.bodyText?.contains("X-Calimero-Proof") == true)
        }
    }

    func testTheRedirectDelegateRefusesEveryRedirect() async throws {
        let url = URL(string: "https://relay.example/x")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let next = await ProofRedirectRefusal().urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.example/x")!))
        XCTAssertNil(next)
        session.invalidateAndCancel()
    }

    // MARK: - MeroConfig.requestProof

    func testMeroSendsNoProofWithoutTheOption() async throws {
        let log = serve(body: #"{"data":{"contexts":[]}}"#)
        let config = MeroConfig(baseURL: URL(string: "https://relay.example")!)
        let mero = Mero(config: config, session: MockURLProtocol.makeSession())
        let admin = await mero.admin
        _ = try? await admin.getContexts()
        XCTAssertNil(log.requests.first?.proof)
    }

    func testMeroUsesACallerSuppliedSignerVerbatim() async throws {
        let log = serve(body: #"{"data":{"contexts":[]}}"#)
        let calls = ProofCallLog()
        let proof = calls.callback(returning: "deadbeef")
        let config = MeroConfig(baseURL: URL(string: "https://relay.example")!, requestProof: .custom(proof))
        let mero = Mero(config: config, session: MockURLProtocol.makeSession())
        let admin = await mero.admin
        _ = try? await admin.getContexts()
        XCTAssertEqual(calls.requests.count, 1)
        XCTAssertEqual(calls.requests.first?.method, "GET")
        XCTAssertTrue(calls.requests.first?.path.hasPrefix("/admin-api/") == true)
        XCTAssertEqual(log.requests.first?.proof, "deadbeef")
    }

    func testMeroMintsProofsItselfWhenGivenKeys() async throws {
        let log = serve(body: #"{"data":{"contexts":[]}}"#)
        let keys = ProofSignerOptions(credential: Self.credential, signerSecret: String(repeating: "65", count: 32))
        let config = MeroConfig(baseURL: URL(string: "https://relay.example")!, requestProof: .keys(keys))
        let mero = Mero(config: config, session: MockURLProtocol.makeSession())
        let admin = await mero.admin
        _ = try? await admin.getContexts()
        let proof = try XCTUnwrap(log.requests.first?.proof)
        XCTAssertTrue(proof.hasPrefix(Self.credential + "00"), proof)
    }

    func testMeroTakesAProofAuthorizer() async throws {
        let log = serve(body: #"{"data":{"contexts":[]}}"#)
        let authorize = try createProofAuthorizer(
            ProofCredential(credential: Self.credential, deviceSecret: String(repeating: "65", count: 32)))
        let config = MeroConfig(baseURL: URL(string: "https://relay.example")!, requestProof: .authorizer(authorize))
        let mero = Mero(config: config, session: MockURLProtocol.makeSession())
        let admin = await mero.admin
        _ = try? await admin.getContexts()
        XCTAssertTrue(log.requests.first?.proof?.hasPrefix(Self.credential + "00") == true)
    }

    // MARK: - SSE

    func testSseSignsTheStreamAndEverySubscription() async throws {
        let log = ProofTransportLog()
        MockURLProtocol.setHandler { req in
            log.append(req)
            if req.url?.path == "/sse" {
                return ScriptedNode.open(Frames.connect("s1"))
            }
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let calls = ProofCallLog()
        let sign = calls.callback(returning: "aa")
        let sse = SseConnection(
            baseURL: URL(string: "https://node.test")!,
            authorize: { request in
                let proof = try await sign(request)
                return ["X-Calimero-Proof": proof ?? ""]
            },
            session: MockURLProtocol.makeSession())
        sse.remember(contextIds: ["c1"], groupIds: [])
        sse.connect()
        defer { sse.close() }
        let subscribed = await eventually { log.requests.count >= 2 }
        XCTAssertTrue(subscribed)
        XCTAssertEqual(log.requests.map(\.proof), ["aa", "aa"])
        XCTAssertNil(log.requests.first?.authorization)
        XCTAssertEqual(calls.requests.first?.method, "GET")
        XCTAssertEqual(calls.requests.first?.path, "/sse")
        let post = try XCTUnwrap(calls.requests.last)
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.path, "/sse/subscription")
        XCTAssertEqual(post.body, log.requests.last?.body, "the signed body is the sent body")
    }

    func testSseRefusesARedirectedStreamWhenCarryingAProof() async throws {
        MockURLProtocol.setHandler { _ in
            .init(status: 307, headers: ["Location": "https://elsewhere.example/sse"], body: Data())
        }
        let sse = SseConnection(
            baseURL: URL(string: "https://node.test")!, authorize: { _ in ["X-Calimero-Proof": "aa"] },
            session: MockURLProtocol.makeSession())
        let log = SyncLog<SseSeen>()
        sse.record(into: log)
        sse.connect()
        defer { sse.close() }
        let failed = await eventually { !log.values.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertEqual(log.values.first, .error(0))
    }
}
