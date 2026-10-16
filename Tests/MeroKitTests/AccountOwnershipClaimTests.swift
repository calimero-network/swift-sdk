import XCTest

@testable import MeroKit

/// Port of mero-js `account-ownership.test.ts`.
final class AccountOwnershipClaimTests: XCTestCase {
    private let secret = String(repeating: "07", count: 32)
    private let namespaceId = String(repeating: "aa", count: 32)
    private let accountId = String(repeating: "bb", count: 32)
    private let salt = String(repeating: "cc", count: 32)
    private let credential = String(repeating: "dd", count: 40)
    private let nowMs: Int64 = 1_700_000_000_000

    private func sessionInput(
        subject: String = "founder@example.com", ttlMs: Int64 = 60_000, salt: String? = nil
    ) -> AccountOwnershipClaimInput {
        AccountOwnershipClaimInput(
            namespaceId: namespaceId, accountId: accountId, salt: salt ?? self.salt, credential: credential,
            subject: subject, deviceSecret: secret, ttlMs: ttlMs, nowMs: nowMs)
    }

    private func haInput(relayURL: String? = nil, ttlMs: Int64 = 60_000) -> AccountHaClaimInput {
        AccountHaClaimInput(
            namespaceId: namespaceId, accountId: accountId, salt: salt, credential: credential, deviceSecret: secret,
            relayURL: relayURL, ttlMs: ttlMs, nowMs: nowMs)
    }

    private func payloadText(_ proof: AccountOwnershipProof) throws -> String {
        String(decoding: try XCTUnwrap(Data(base64Encoded: proof.signedPayload)), as: UTF8.self)
    }

    private func payload(_ proof: AccountOwnershipProof) throws -> JSONValue {
        try MeroJSON.decode(JSONValue.self, from: Data(try payloadText(proof).utf8))
    }

    /// Whether the device key signed `DOMAIN ‖ payload` (or, `bare`, the payload alone).
    private func verifies(_ proof: AccountOwnershipProof, bare: Bool = false) throws -> Bool {
        let signer = try signerFromSecret(secret)
        let publicKey = try Hex.decode(signer.publicKey, label: "pk", bytes: 32)
        let bytes = try XCTUnwrap(Data(base64Encoded: proof.signedPayload))
        let message = bare ? bytes : Data("calimero.mdma.account-ownership-claim.v1\u{0}".utf8) + bytes
        let signature = try XCTUnwrap(Data(base64Encoded: proof.signature))
        return Ed25519.verify(publicKey: publicKey, signature: signature, message: message)
    }

    private func keyOrder(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #""([a-z_]+)":"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testBuildsTheSessionClaimAndSignsDomainAndPayloadWithTheDeviceKey() async throws {
        let proof = try await signAccountOwnershipClaim(sessionInput())
        XCTAssertEqual(proof.kind, "account")
        XCTAssertEqual(proof.credential, credential)
        let body = try payload(proof)
        XCTAssertEqual(body["v"], 1)
        XCTAssertEqual(body["audience"], "mdma:enable-ha-namespace")
        XCTAssertEqual(body["group_id"]?.stringValue, namespaceId)
        XCTAssertEqual(body["account_id"]?.stringValue, accountId)
        XCTAssertEqual(body["salt"]?.stringValue, salt)
        XCTAssertEqual(body["subject"], "founder@example.com")
        XCTAssertEqual(body["issued_at_ms"]?.doubleValue, 1_700_000_000_000)
        XCTAssertEqual(body["expires_at_ms"]?.doubleValue, 1_700_000_060_000)
        let nonce = try XCTUnwrap(body["nonce"]?.stringValue)
        XCTAssertEqual(nonce.count, 32)
        XCTAssertEqual(
            keyOrder(try payloadText(proof)),
            ["v", "audience", "group_id", "account_id", "salt", "subject", "nonce", "issued_at_ms", "expires_at_ms"])
        XCTAssertTrue(try verifies(proof))
    }

    func testRefusesALifetimeTheCloudWouldRefuseAMissingSubjectAndMalformedIds() async {
        let bad: [(AccountOwnershipClaimInput, String)] = [
            (sessionInput(ttlMs: 5 * 60_000 + 1), "ttlMs"), (sessionInput(subject: ""), "subject"),
            (sessionInput(salt: "zz"), "salt"),
        ]
        for (input, word) in bad {
            do {
                _ = try await signAccountOwnershipClaim(input)
                XCTFail("expected a refusal naming \(word)")
            } catch {
                XCTAssertTrue("\(error)".contains(word), "\(error)")
            }
        }
    }

    func testBuildsTheAnonymousRouteClaimWithItsOwnAudienceAndExactKeySet() async throws {
        let proof = try await signAccountHaClaim(haInput())
        XCTAssertEqual(AccountHaClaim.audience, "mdma:enable-ha-namespace-as-account")
        XCTAssertEqual(
            keyOrder(try payloadText(proof)),
            ["v", "audience", "group_id", "account_id", "salt", "nonce", "issued_at_ms", "expires_at_ms"])
        let body = try payload(proof)
        XCTAssertNil(body["subject"])
        XCTAssertEqual(body["audience"], "mdma:enable-ha-namespace-as-account")
        XCTAssertTrue(try verifies(proof))
        XCTAssertFalse(try verifies(proof, bare: true), "the domain is load-bearing")
    }

    func testLowercasesIdsHonoursTtlUpToFiveMinutesAndRefusesBeyondIt() async throws {
        let proof = try await signAccountHaClaim(
            AccountHaClaimInput(
                namespaceId: namespaceId.uppercased(), accountId: accountId.uppercased(), salt: salt.uppercased(),
                credential: credential, deviceSecret: secret, ttlMs: 300_000, nowMs: nowMs))
        let body = try payload(proof)
        XCTAssertEqual(body["group_id"]?.stringValue, namespaceId)
        XCTAssertEqual(body["account_id"]?.stringValue, accountId)
        XCTAssertEqual(body["salt"]?.stringValue, salt)
        let issued = try XCTUnwrap(body["issued_at_ms"]?.doubleValue)
        let expires = try XCTUnwrap(body["expires_at_ms"]?.doubleValue)
        XCTAssertEqual(expires - issued, 300_000)
        for ttl: Int64 in [300_001, 0] {
            do {
                _ = try await signAccountHaClaim(haInput(ttlMs: ttl))
                XCTFail("ttl \(ttl) must be refused")
            } catch {
                XCTAssertTrue("\(error)".contains("ttlMs"))
            }
        }
    }

    func testAppendsRelayUrlLastWhenGivenAndOmitsItOtherwise() async throws {
        let proof = try await signAccountHaClaim(haInput(relayURL: "https://node-abc.relay.cloud.test"))
        XCTAssertEqual(keyOrder(try payloadText(proof)).last, "relay_url")
        XCTAssertEqual(try payload(proof)["relay_url"], "https://node-abc.relay.cloud.test")
        XCTAssertTrue(try verifies(proof))
        let plain = try await signAccountHaClaim(haInput())
        XCTAssertNil(try payload(plain)["relay_url"])
        for relay in ["", String(repeating: "x", count: 1025)] {
            do {
                _ = try await signAccountHaClaim(haInput(relayURL: relay))
                XCTFail("relay \(relay.count) must be refused")
            } catch {
                XCTAssertTrue("\(error)".contains("relayUrl"))
            }
        }
    }

    func testMatchesTheDeviceKeysFormByteForByte() async throws {
        let keys = try DeviceKeys(
            signSecret: try Hex.decode(secret, label: "s", bytes: 32), kemSecret: Data(repeating: 1, count: 32))
        var fields = AccountHaClaim.ClaimFields(
            namespaceId: namespaceId, accountId: accountId, salt: salt, credential: credential, ttlMs: 60_000,
            nowMs: nowMs)
        fields.nonce = String(repeating: "0", count: 32)
        let viaSigner = try await AccountHaClaim.signClaim(
            fields, signer: try signerFromSecret(secret), audience: AccountHaClaim.audience, subject: nil,
            relayURL: nil)
        let viaKeys = try AccountHaClaim.sign(
            namespaceId: namespaceId, accountId: accountId, salt: salt, credential: credential, keys: keys,
            nowMs: nowMs, nonce: String(repeating: "0", count: 32))
        XCTAssertEqual(viaSigner, viaKeys)
    }

    func testCannotStandInForTheSessionClaim() async throws {
        XCTAssertNotEqual(AccountHaClaim.ownershipAudience, AccountHaClaim.audience)
        let session = try await signAccountOwnershipClaim(sessionInput())
        XCTAssertEqual(try payload(session)["audience"], "mdma:enable-ha-namespace")
    }

    func testRefusesASecretAndASignerAtOnce() async throws {
        var input = sessionInput()
        input.signer = try signerFromSecret(secret)
        do {
            _ = try await signAccountOwnershipClaim(input)
            XCTFail("both forms must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("not both"))
        }
    }
}
