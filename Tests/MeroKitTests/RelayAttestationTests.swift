import Foundation
import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Port of mero-js `relay-attestation/attest-node-key.test.ts`, plus the
/// quote-verifying ``DcapRelayKeyVerifier`` and the delegated relay sealing
/// (`relayTransportFetch`) it backs.
final class RelayAttestationTests: XCTestCase {
    private let key = try! Hex.decode(
        "3d46b7386e1cfa0a61c94eb3087ca7bb316ab1dd2b71974d9d524ad268088d8a", label: "k", bytes: 32)
    private let mockHeader = Data("MOCK_TDX_QUOTE_V1".utf8)

    override func tearDown() {
        MockURLProtocol.reset()
        DelegatedAccounts.forgetRelaySealing()
        super.tearDown()
    }

    /// A relay answering `/tee/attest`, binding `boundKey` but naming `namedKey`.
    private func relay(
        namedKey: Data? = nil, boundKey: Data? = nil, mock: Bool = true, wrongNonce: Bool = false,
        collateral: JSONValue? = nil, sent: SealedTestRecorder<JSONValue>? = nil
    ) {
        let named = namedKey ?? key
        let bound = boundKey ?? named
        let header = mockHeader
        MockURLProtocol.setHandler { request in
            let body = (try? MeroJSON.decode(JSONValue.self, from: FakeNode.body(request))) ?? .null
            sent?.record(body)
            var nonce = [UInt8]((try? Hex.decode(body["nonce"]?.stringValue ?? "", label: "n", bytes: 32)) ?? Data())
            if wrongNonce, !nonce.isEmpty { nonce[0] ^= 0xff }
            let reportData = Data(nonce) + attestKeyBinding(bound)
            var quote: Data
            if mock {
                quote = Data(count: 256)
                quote.replaceSubrange(0..<header.count, with: header)
                quote.replaceSubrange(header.count..<header.count + 64, with: reportData)
            } else {
                quote = Data(count: 1024)
                quote.replaceSubrange(568..<632, with: reportData)
            }
            var data: [String: JSONValue] = [
                "quoteB64": .string(quote.base64EncodedString()), "boundPublicKey": .string(Hex.encode(named)),
            ]
            if let collateral { data["collateral"] = collateral }
            let json = CanonicalJSON.string(["data": .object(data)])
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
    }

    private func attest(
        allowMock: Bool = false, verify: (any TransportQuoteVerifier)? = nil,
        verifyQuote: (@Sendable (Data) async throws -> Void)? = nil
    ) async throws -> AttestedNodeKey {
        try await attestRelayNodeKey(
            AttestRelayNodeKeyOptions(
                relayURL: "https://r", allowMock: allowMock, verify: verify, verifyQuote: verifyQuote,
                session: MockURLProtocol.makeSession()))
    }

    private func refusal(
        allowMock: Bool = false, verify: (any TransportQuoteVerifier)? = nil
    ) async -> String? {
        await teeAsyncThrownMessage { _ = try await self.attest(allowMock: allowMock, verify: verify) }
    }

    // MARK: - attestRelayNodeKey

    func testReturnsTheKeyAMockQuoteBindsWhenMockIsAllowed() async throws {
        relay()
        let got = try await attest(allowMock: true)
        XCTAssertEqual(got, AttestedNodeKey(nodeKey: Hex.encode(key), mock: true))
    }

    func testRefusesAMockQuoteUnlessToldOtherwise() async {
        relay()
        assertTeeRefusal(await refusal(), "MOCK")
    }

    func testRefusesAKeyTheQuoteDoesNotBind() async {
        relay(namedKey: Data(repeating: 7, count: 32), boundKey: key)
        assertTeeRefusal(await refusal(allowMock: true), "does not bind the key")
    }

    func testRefusesAQuoteMadeForAnotherNonce() async {
        relay(wrongNonce: true)
        assertTeeRefusal(await refusal(allowMock: true), "nonce")
    }

    func testRefusesARealQuoteWithNoVerifierAndRunsTheVerifierWhenGivenOne() async throws {
        relay(mock: false)
        assertTeeRefusal(await refusal(), "verify")
        let verified = Counter()
        let got = try await attest(verifyQuote: { _ in verified.increment() })
        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(got, AttestedNodeKey(nodeKey: Hex.encode(key), mock: false))
    }

    func testChecksARealQuoteWithATransportVerifierOurNonceTheKeyBindingTheCollateral() async throws {
        let collateral = try MeroJSON.decode(JSONValue.self, from: try TeeFixture.data("tdx_quote_collateral.json"))
        let sent = SealedTestRecorder<JSONValue>()
        relay(mock: false, collateral: collateral, sent: sent)
        let seen = SealedTestRecorder<TransportQuoteArgs>()
        let verifier = AnyTransportQuoteVerifier(includeCollateral: true) { args in
            seen.record(args)
            return true
        }
        let got = try await attest(verify: verifier)
        XCTAssertEqual(got, AttestedNodeKey(nodeKey: Hex.encode(key), mock: false))
        let body = try XCTUnwrap(sent.values.first)
        XCTAssertEqual(body["includeCollateral"], true)
        XCTAssertEqual(body["bindNodeKey"], true)
        let args = try XCTUnwrap(seen.values.first)
        XCTAssertEqual(args.nonce, body["nonce"]?.stringValue)
        XCTAssertEqual(args.reportDataSuffix, Hex.encode(attestKeyBinding(key)))
        XCTAssertEqual(args.collateral, try TeeFixture.collateral)
    }

    func testRefusesWhenTheTransportVerifierDoesNotAcceptTheQuote() async {
        relay(mock: false)
        assertTeeRefusal(await refusal(verify: AnyTransportQuoteVerifier { _ in false }), "did not verify")
    }

    // Captured from a mock-TEE merod (core rc.60, `merod run --mock-tee`)
    // answering POST /admin-api/tee/attest { nonce, bindNodeKey: true }.
    func testReadsTheNonceAndTheKeyBindingOutOfARealCoreResponse() throws {
        let nonce = "912466d433e9fb59fa3efc199c570f7afa7a0517cc4d868bcceeb324b9f896e6"
        let quoteB64 =
            "TU9DS19URFhfUVVPVEVfVjGRJGbUM+n7Wfo+/BmcVw96+noFF8xNhovM7rMkufiW5oay/bvn9kdYWwIO5cDHwshQazm9T8Mr"
            + "g7LUZwLXS/TM" + String(repeating: "A", count: 234) + "=="
        let quote = try XCTUnwrap(Data(base64Encoded: quoteB64))
        let (reportData, mock) = try reportDataOf(quote)
        XCTAssertTrue(mock)
        XCTAssertEqual(Hex.encode(reportData.prefix(32)), nonce)
        XCTAssertEqual(Hex.encode(reportData.suffix(32)), Hex.encode(attestKeyBinding(key)))
    }

    // MARK: - DcapRelayKeyVerifier

    private func attestation(
        _ quote: Data, relayURL: String = "https://relay.example", nonce: Data, collateral: JSONValue? = nil
    ) -> RelayAttestation {
        RelayAttestation(
            relayURL: relayURL, nonce: Hex.encode(nonce), quoteB64: quote.base64EncodedString(),
            boundPublicKey: Hex.encode(key), collateral: collateral)
    }

    func testRefusesAMockEvenFromALoopbackRelayUnlessAllowed() async throws {
        let nonce = randomBytes(32)
        let quote = mockHeader + nonce + attestKeyBinding(key)
        let never = AnyTransportQuoteVerifier { _ in
            XCTFail("a mock quote is never sent to the verifier")
            return true
        }
        let verifier = DcapRelayKeyVerifier(verifier: never)
        // Another app on the device can listen on 127.0.0.1.
        let local = await teeAsyncThrownMessage {
            _ = try await verifier.verify(self.attestation(quote, relayURL: "http://localhost:2428", nonce: nonce))
        }
        assertTeeRefusal(local, "MOCK")
        let hosted = await teeAsyncThrownMessage {
            _ = try await verifier.verify(self.attestation(quote, nonce: nonce))
        }
        assertTeeRefusal(hosted, "MOCK")

        let devRig = DcapRelayKeyVerifier(verifier: never, allowMock: true)
        let accepted = try await devRig.verify(attestation(quote, relayURL: "http://localhost:2428", nonce: nonce))
        XCTAssertEqual(accepted, Hex.encode(key))
    }

    func testVerifiesARealQuoteByItsVerifierThenItsBinding() async throws {
        let nonce = randomBytes(32)
        var quote = Data(count: 1024)
        quote.replaceSubrange(568..<632, with: nonce + attestKeyBinding(key))
        let collateral = try MeroJSON.decode(JSONValue.self, from: try TeeFixture.data("tdx_quote_collateral.json"))
        let seen = SealedTestRecorder<TransportQuoteArgs>()
        let asked = SealedTestRecorder<String>()
        let verifier = DcapRelayKeyVerifier(verifierFor: { relayURL in
            asked.record(relayURL)
            return AnyTransportQuoteVerifier(includeCollateral: true) { args in
                seen.record(args)
                return true
            }
        })
        let nodeKey = try await verifier.verify(attestation(quote, nonce: nonce, collateral: collateral))
        XCTAssertEqual(nodeKey, Hex.encode(key))
        XCTAssertEqual(asked.values, ["https://relay.example"])
        let args = try XCTUnwrap(seen.values.first)
        XCTAssertEqual(args.nonce, Hex.encode(nonce))
        XCTAssertEqual(args.reportDataSuffix, Hex.encode(attestKeyBinding(key)))
        XCTAssertEqual(args.collateral, try TeeFixture.collateral)

        let refusing = DcapRelayKeyVerifier(verifier: AnyTransportQuoteVerifier { _ in false })
        let refused = await teeAsyncThrownMessage {
            _ = try await refusing.verify(self.attestation(quote, nonce: nonce))
        }
        assertTeeRefusal(refused, "did not verify")
    }

    func testRefusesTheRealSampleQuoteWhoseImageIsNoMeroTeeRelease() async throws {
        // The relay names 2.3.87; its quote is dcap-qvl's sample, not of that image.
        let rig = CloudRig()
        rig.install()
        let image = "merotee-ubuntu-questing-25-10-locked-read-only-2-3-87"
        rig.on("GET", "/admin-api/tee/info", json: #"{"data":{"cloudProvider":"gcp","osImage":"\#(image)"}}"#)
        let signed = try TeeFixture.signed("2.3.87")
        rig.on(
            "GET", "/api/tee/node-releases/2.3.87",
            json: CanonicalJSON.string([
                "data": [
                    "version": .string(signed.version), "publishedMrtds": .string(signed.publishedMrtds),
                    "bundle": .string(signed.bundle),
                ]
            ]))
        let verifier = DcapRelayKeyVerifier(
            session: MockURLProtocol.makeSession(), minReleaseVersion: "2.3.86", now: { TeeFixture.at })
        let quote = try TeeFixture.quote
        let collateral = try MeroJSON.decode(JSONValue.self, from: try TeeFixture.data("tdx_quote_collateral.json"))
        let nonce = try Hex.decode(TeeFixture.nonce, label: "n", bytes: 32)
        let refusal = await teeAsyncThrownMessage {
            _ = try await verifier.verify(self.attestation(quote, nonce: nonce, collateral: collateral))
        }
        assertTeeRefusal(refusal, "are not an image this verifier trusts")
        XCTAssertEqual(rig.requests("GET", "/admin-api/tee/info").count, 1)
    }

    func testCallsAReleaseMirrorThatDoesNotAnswerATransportFailure() async throws {
        MockURLProtocol.setHandler { _ in .init(status: 503, headers: [:], body: Data()) }
        let verifier = DcapRelayKeyVerifier(session: MockURLProtocol.makeSession())
        let quote = try TeeFixture.quote
        let collateral = try MeroJSON.decode(JSONValue.self, from: try TeeFixture.data("tdx_quote_collateral.json"))
        do {
            _ = try await verifier.verify(attestation(quote, nonce: randomBytes(32), collateral: collateral))
            XCTFail("expected the release fetch to fail")
        } catch {
            XCTAssertTrue(error is RelayKeyTransportError, "\(error)")
            XCTAssertTrue(DelegatedAccounts.isTransportFailure(error))
        }
    }

    // MARK: - Delegated relay sealing

    func testSealsAHostedRelayAndNeverALoopbackOneOrWhenTurnedOff() {
        let env = DelegatedEnvironment(store: .memory(), urlSession: MockURLProtocol.makeSession())
        XCTAssertTrue(env.relayKeyVerifier is DcapRelayKeyVerifier, "relays are verified by quote by default")
        XCTAssertTrue(env.sealRelays)
        let hosted = DelegatedAccounts.relayTransportSession("https://relay.example/", env: env)
        XCTAssertFalse(hosted === env.urlSession)
        XCTAssertTrue(DelegatedAccounts.relayTransportSession("https://relay.example", env: env) === hosted)
        XCTAssertTrue(
            DelegatedAccounts.relayTransportSession("http://127.0.0.1:2428", env: env) === env.urlSession)
        var plain = env
        plain.sealRelays = false
        XCTAssertTrue(DelegatedAccounts.relayTransportSession("https://relay.example", env: plain) === env.urlSession)
        DelegatedAccounts.forgetRelaySealing()
        XCTAssertFalse(DelegatedAccounts.relayTransportSession("https://relay.example", env: env) === hosted)
    }
}
