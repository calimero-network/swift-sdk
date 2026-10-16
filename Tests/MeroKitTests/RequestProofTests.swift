import XCTest

@testable import MeroKit

/// Request signatures and `X-Calimero-Proof`, against core's pinned vectors
/// (`crates/account/src/tests/request_wire_fixture.rs` and `proof_auth.rs`'s
/// `chain_for(1, key(7))`), ported from mero-js `request-sig.test.ts`,
/// `caller-proof.test.ts` and `proof-signer.test.ts`. A signed link is
/// compared up to its 64-byte signature and the signature verified
/// (CryptoKit's Ed25519 is randomized); core's own signatures are verified
/// against the payloads computed here.
final class RequestProofTests: XCTestCase {
    /// core's `key(3)`.
    private static let signerSecret = String(repeating: "03", count: 32)
    /// `chain_for`'s session key, `PrivateKey::from([101; 32])`.
    private static let sessionSecret = String(repeating: "65", count: 32)
    private static let method = "GET"
    private static let path = "/admin-api/namespaces?limit=5&q=a%2Fb"
    private static let body = #"{"k":"v"}"#
    private static let issuedAt: UInt64 = 1_700_000_000
    private static let expiresAt: UInt64 = 1_700_000_300

    /// core's recorded `RequestSig` for the inputs above.
    private static let recorded =
        "03000000" + "474554"
        + "25000000" + "2f61646d696e2d6170692f6e616d657370616365" + "733f6c696d69743d3526713d6125324662"
        + "3b26137eb7b296bdf7d84b9193dd52d1947b2056731f38020f4a3b9b88d95121"
        + "00f1536500000000" + "2cf2536500000000"
        + "fab437d01e5fe97a376e9165a55e0ec91e73325b08bb997c8755776df0939d2f"
        + "c3001455d4c08e306244afd2f050c30a01237aa06187e185fc0a671941c8ac09"

    private static let credential =
        "028a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c0000000004cfa21629a77f8cd8ddd3"
        + "f821ed514009a9f572b2ce8e0a11f5cbb5e25340b0222222222222222222222222222222229aeef190d5865e90861a94"
        + "ec2e0b28de17cb79fb2b4120f2b1ec65e4198d6e08b28e813feb01e4a400839b85e18080ce0909090909090909090909"
        + "0909090909090909090909090909090909090909090000000000000000bba802950e323563e8cef9867dfd562dfbd50e"
        + "106ccd07c779acf3e4daba6a964e0d1354ee521747c38e0aa9839d9460dbc5a278822ac729e58f62ed8835120f"
    private static let session =
        "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c02777777777777777777777777777777"
        + "7777777777777777777777777777777777d62f016a1efd1e4fdf793eb42cd84471e1ba9f0cf04d1287b5cc71f616287c"
        + "b817cb79fb2b4120f2b1ec65e4198d6e08b28e813feb01e4a400839b85e18080ce00f153650000000010ff5365000000"
        + "0056554af3cbf04380c22898aa2b15397f526d9dec50ab792b76fd45ca01668488be57b317015d9e4aada80a8dda0367"
        + "f7390071051e2b3855c5e7eeaf0119520c"
    private static let request =
        "03000000474554150000002f61646d696e2d6170692f6e616d65737061636573ea5bb92ca52d40a333e56e353225c6a5"
        + "69e2afbcb7a9152aa9727bed602872f900f15365000000002cf2536500000000603ab514b9df40ba389f9eae5d3c3040"
        + "fa9ef473a4e00ac0000f8db1b08f50ada268bbcf7daf351e6afec3176e7aa2f6c5cab57a2ff930bd7962035358a8db0c"

    private func publicKey(_ secret: String) throws -> Data {
        try Ed25519.publicKey(seed: try Hex.decode(secret, label: "secret", bytes: 32))
    }

    private func signature(_ hex: String) throws -> Data {
        try Hex.decodeUnsized(String(hex.suffix(128)), label: "signature")
    }

    private func input(
        method: String = RequestProofTests.method, path: String = RequestProofTests.path,
        body: String = RequestProofTests.body, issuedAt: UInt64 = RequestProofTests.issuedAt,
        expiresAt: UInt64 = RequestProofTests.expiresAt
    ) -> RequestSigInput {
        RequestSigInput(
            method: method, path: path, body: Data(body.utf8), issuedAt: issuedAt, expiresAt: expiresAt,
            signerSecret: Self.signerSecret)
    }

    // MARK: - signRequest

    func testCommitsToTheBodyUnderItsOwnDomain() {
        XCTAssertEqual(
            Hex.encode(requestBodyHash(Self.body)), "3b26137eb7b296bdf7d84b9193dd52d1947b2056731f38020f4a3b9b88d95121")
    }

    func testCommitsToAnEmptyBodyTooAndToADifferentValue() {
        let empty = Hex.encode(requestBodyHash())
        XCTAssertNotEqual(empty, String(repeating: "0", count: 64))
        XCTAssertNotEqual(empty, Hex.encode(requestBodyHash(Self.body)))
    }

    func testReproducesCoresRecordedEncoding() async throws {
        let signed = try await signRequest(input())
        XCTAssertEqual(signed.dropLast(128), Self.recorded.dropLast(128))
        let payload = requestSigningPayload(
            method: Self.method, path: Self.path, bodyHash: requestBodyHash(Self.body), issuedAt: Self.issuedAt,
            expiresAt: Self.expiresAt)
        let key = try publicKey(Self.signerSecret)
        XCTAssertTrue(Ed25519.verify(publicKey: key, signature: try signature(Self.recorded), message: payload))
        XCTAssertTrue(Ed25519.verify(publicKey: key, signature: try signature(signed), message: payload))
    }

    func testEveryFieldReachesThePreimage() {
        let bodyHash = requestBodyHash(Self.body)
        let original = requestSigningPayload(
            method: Self.method, path: Self.path, bodyHash: bodyHash, issuedAt: Self.issuedAt,
            expiresAt: Self.expiresAt)
        let changed = [
            requestSigningPayload(
                method: "POST", path: Self.path, bodyHash: bodyHash, issuedAt: Self.issuedAt,
                expiresAt: Self.expiresAt),
            requestSigningPayload(
                method: Self.method, path: "/admin-api/namespaces?q=a%2Fb&limit=5", bodyHash: bodyHash,
                issuedAt: Self.issuedAt, expiresAt: Self.expiresAt),
            requestSigningPayload(
                method: Self.method, path: "/admin-api/namespaces?limit=5&q=a/b", bodyHash: bodyHash,
                issuedAt: Self.issuedAt, expiresAt: Self.expiresAt),
            requestSigningPayload(
                method: Self.method, path: Self.path, bodyHash: requestBodyHash(#"{"k":"w"}"#),
                issuedAt: Self.issuedAt, expiresAt: Self.expiresAt),
            requestSigningPayload(
                method: Self.method, path: Self.path, bodyHash: bodyHash, issuedAt: Self.issuedAt + 1,
                expiresAt: Self.expiresAt),
            requestSigningPayload(
                method: Self.method, path: Self.path, bodyHash: bodyHash, issuedAt: Self.issuedAt,
                expiresAt: Self.expiresAt + 1),
            requestSigningPayload(
                method: "HEAD", path: Self.path, bodyHash: bodyHash, issuedAt: Self.issuedAt,
                expiresAt: Self.expiresAt),
        ]
        for payload in changed { XCTAssertNotEqual(payload, original) }
    }

    func testDoesNotFoldHeadIntoGet() async throws {
        let head = try await signRequest(input(method: "HEAD"))
        let get = try await signRequest(input(method: "GET"))
        XCTAssertNotEqual(head.dropLast(128), get.dropLast(128))
    }

    func testMatchesSignRequestProofsRequestLink() async throws {
        let link = try await signRequest(input())
        let proof = try await signRequestProof(
            RequestProofInput(
                method: Self.method, path: Self.path, body: Data(Self.body.utf8), credential: "ab",
                deviceSecret: Self.signerSecret, validForSeconds: Self.expiresAt - Self.issuedAt, now: Self.issuedAt))
        XCTAssertEqual(proof.dropLast(128), ("ab00" + link).dropLast(128))
    }

    func testSignRequestProofRefusesWhatItCannotSign() async {
        let cases: [(RequestProofInput, String)] = [
            (RequestProofInput(method: "", path: "/x", credential: "ab", deviceSecret: Self.signerSecret), "method"),
            (RequestProofInput(method: "GET", path: "x", credential: "ab", deviceSecret: Self.signerSecret), "path"),
            (RequestProofInput(method: "GET", path: "/x", credential: "ab"), "deviceSecret"),
        ]
        for (input, pattern) in cases {
            do {
                _ = try await signRequestProof(input)
                XCTFail("expected a refusal naming \(pattern)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(pattern), "\(error)")
            }
        }
    }

    // MARK: - callerProof

    func testCallerProofMatchesCoreForAThreeLinkChain() throws {
        XCTAssertEqual(
            try callerProof(
                CallerProofInput(credential: Self.credential, session: Self.session, request: Self.request)),
            Self.credential + "01" + Self.session + Self.request)
    }

    func testCallerProofMatchesCoreForATwoLinkChain() throws {
        XCTAssertEqual(
            try callerProof(CallerProofInput(credential: Self.credential, request: Self.request)),
            Self.credential + "00" + Self.request)
    }

    func testAnOmittedSessionIsNotAnEmptyOne() throws {
        let omitted = try callerProof(CallerProofInput(credential: Self.credential, request: Self.request))
        let empty = try callerProof(CallerProofInput(credential: Self.credential, session: "", request: Self.request))
        XCTAssertNotEqual(omitted, empty)
        XCTAssertEqual(omitted.dropFirst(Self.credential.count).prefix(2), "00")
        XCTAssertEqual(empty.dropFirst(Self.credential.count).prefix(2), "01")
    }

    func testCallerProofRefusesInputThatIsNotHex() {
        XCTAssertThrowsError(try callerProof(CallerProofInput(credential: "nothex", request: Self.request))) {
            XCTAssertTrue($0.localizedDescription.contains("credential"))
        }
        XCTAssertThrowsError(try callerProof(CallerProofInput(credential: Self.credential, request: "abc"))) {
            XCTAssertTrue($0.localizedDescription.contains("request signature"))
        }
    }

    // MARK: - createProofSigner

    func testProofSignerReproducesCoresCallerProof() async throws {
        let sign = try createProofSigner(
            ProofSignerOptions(
                credential: Self.credential, session: Self.session, signerSecret: Self.sessionSecret, ttlSeconds: 300,
                now: { 1_700_000_000 }))
        let proof = try await sign(ProofRequest(method: "GET", path: "/admin-api/namespaces"))
        let expected = Self.credential + "01" + Self.session + Self.request
        XCTAssertEqual(proof?.dropLast(128), expected.dropLast(128))
        // core's request link verifies against the session key over this payload.
        let payload = requestSigningPayload(
            method: "GET", path: "/admin-api/namespaces", bodyHash: requestBodyHash(), issuedAt: 1_700_000_000,
            expiresAt: 1_700_000_300)
        let key = try publicKey(Self.sessionSecret)
        XCTAssertTrue(Ed25519.verify(publicKey: key, signature: try signature(Self.request), message: payload))
        XCTAssertTrue(Ed25519.verify(publicKey: key, signature: try signature(proof ?? ""), message: payload))
    }

    func testProofSignerProducesTheTwoLinkEncodingWithoutASession() async throws {
        let sign = try createProofSigner(
            ProofSignerOptions(
                credential: Self.credential, signerSecret: Self.sessionSecret, ttlSeconds: 300, now: { 1_700_000_000 }))
        let proof = try await sign(ProofRequest(method: "GET", path: "/admin-api/namespaces"))
        XCTAssertEqual(proof?.dropLast(128), (Self.credential + "00" + Self.request).dropLast(128))
    }

    func testProofSignerDefaultsToA120SecondExpiry() async throws {
        let sign = try createProofSigner(
            ProofSignerOptions(credential: Self.credential, signerSecret: Self.sessionSecret, now: { 1_700_000_000 }))
        let signed = try await sign(ProofRequest(method: "GET", path: "/admin-api/namespaces"))
        let proof = try XCTUnwrap(signed)
        // expires_at is the u64 just before the signature.
        let expires = String(proof.dropLast(128).suffix(16))
        XCTAssertEqual(expires, Hex.encode(LittleEndian.u64(1_700_000_120)))
    }

    // MARK: - createProofAuthorizer / signedPath

    func testAuthorizerReturnsTheProofHeader() async throws {
        let authorize = try createProofAuthorizer(
            ProofCredential(credential: Self.credential, deviceSecret: Self.signerSecret))
        let headers = try await authorize(ProofRequest(method: "GET", path: "/admin-api/contexts"))
        let proof = try XCTUnwrap(headers[requestProofHeader])
        XCTAssertTrue(proof.hasPrefix(Self.credential + "00"))
        XCTAssertEqual(requestProofHeader, "X-Calimero-Proof")
    }

    func testAuthorizerValidatesTheCredentialUpFront() {
        let secret = Self.signerSecret
        XCTAssertThrowsError(try createProofAuthorizer(ProofCredential(credential: "", deviceSecret: secret)))
        XCTAssertThrowsError(try createProofAuthorizer(ProofCredential(credential: Self.credential)))
        XCTAssertThrowsError(try createProofAuthorizer(ProofCredential(credential: "zz", deviceSecret: secret)))
    }

    func testSignedPathKeepsTheQueryAsSentAndThePrefix() {
        XCTAssertEqual(
            signedPath(URL(string: "https://relay.example/admin-api/blobs/b?hash=h&context_id=a%2Fb%20c")!),
            "/admin-api/blobs/b?hash=h&context_id=a%2Fb%20c")
        XCTAssertEqual(
            signedPath(URL(string: "https://relay.example/node-7/admin-api/contexts")!), "/node-7/admin-api/contexts")
        XCTAssertEqual(signedPath(URL(string: "https://relay.example")!), "/")
        XCTAssertEqual(signedPath(URL(string: "https://relay.example/x?q=what?")!), "/x?q=what?")
        XCTAssertEqual(signedPath(URL(string: "https://relay.example/x?#frag")!), "/x")
        XCTAssertEqual(signedPath("/x?a=1"), "/x?a=1")
    }

    func testCarriesProofIsCaseInsensitive() {
        XCTAssertTrue(carriesProof(["x-calimero-proof": "aa"]))
        XCTAssertFalse(carriesProof(["Authorization": "Bearer t"]))
    }
}
