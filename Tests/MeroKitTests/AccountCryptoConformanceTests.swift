import XCTest

@testable import MeroKit

/// Conformance of the account layer's byte layouts against the golden vectors
/// mero-js pins — which are themselves core's own wire fixtures
/// (`crates/account/src/tests/*_wire_fixture.rs`, `sdk_credential_fixture.rs`)
/// and MDMA's routing-proof fixture.
///
/// CryptoKit's Ed25519 is randomized, so a signature here is never compared
/// byte for byte. What is compared is everything *but* the signature — the
/// preimages, hashes and wire layout — and then the golden (deterministic)
/// signature from core is **verified against the preimage computed here**,
/// which is the check that the preimage is core's.
final class AccountCryptoConformanceTests: XCTestCase {
    private func hex(_ data: Data) -> String { Hex.encode(data) }
    private func bytes(_ hex: String) -> Data { try! Hex.decodeUnsized(hex, label: "fixture") }
    private func rep(_ byte: String, _ count: Int = 32) -> String { String(repeating: byte, count: count) }

    // MARK: - Primitives

    func testHexRoundTripAndRefusals() throws {
        XCTAssertEqual(Hex.encode(Data([0x00, 0xAB, 0xFF])), "00abff")
        XCTAssertEqual(try Hex.decode("00ABff", label: "x", bytes: 3), Data([0x00, 0xAB, 0xFF]))
        XCTAssertThrowsError(try Hex.decode("abcd", label: "node", bytes: 32)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("node must be 64 hex characters"))
        }
        XCTAssertThrowsError(try Hex.decodeUnsized("zz", label: "x"))
        XCTAssertThrowsError(try Hex.decodeUnsized("abc", label: "x"))
    }

    func testLittleEndianWriter() {
        var w = BorshWriter()
        w.u32(5)
        w.u64(1_700_000_000)
        w.string("set")
        w.optionBytes(nil)
        w.optionBytes(Data("general".utf8))
        XCTAssertEqual(
            hex(w.data),
            "05000000" + "00f1536500000000" + "03000000736574" + "00" + "010700000067656e6572616c")
    }

    func testCanonicalJSONSortsKeysAndMatchesJSONStringify() {
        XCTAssertEqual(CanonicalJSON.string(["value": "v", "key": "k"]), #"{"key":"k","value":"v"}"#)
        XCTAssertEqual(
            CanonicalJSON.string(["a": [1, 2.5, nil, true], "b": "x/y\n\"é"]),
            #"{"a":[1,2.5,null,true],"b":"x/y\n\"é"}"#)
        XCTAssertEqual(CanonicalJSON.string([:]), "{}")
    }

    // MARK: - Device certificate (mero-js device-cert.test.ts)

    private let coreSdkCredential =
        "02ed6a47a39da869b5446155e40b2d93f1e3f0167be26732bae7a3ef9d8e3a3fd300000000ca999783990fd7f4ea0c192135f78c"
        + "17ac77745bf580b2ed20fea455a8133845a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1044305da225179a277d6d96e07ff21ea8b237d"
        + "788e8eaaef550c6d125823fa45f1fd5fc29b2c88bdf871119471fc13123a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a"
        + "3a3a3a3a3a3a3a3a3a00000000000000004ba6c450e21f28d01b03c2fcb10a5c188a388ef6298fcb1ec23d381b7acc8f3386f08d"
        + "81672c9089d2ad7bf0ff180ccad61163baa852a021c6773e625aed8a00"

    func testMintsTheDeviceIdCoreMints() throws {
        XCTAssertEqual(
            try DeviceCertificates.mintDeviceId(account: rep("11"), nonce: Data(repeating: 0x22, count: 16)),
            "222222222222222222222222222222227042c913b557a30a2cbabcaccdbecd10")
        XCTAssertThrowsError(try DeviceCertificates.mintDeviceId(account: rep("11"), nonce: Data(count: 8)))
    }

    func testComputesTheCertPayloadARootSigns() throws {
        let payload = try DeviceCertificates.payload(
            account: rep("11"), device: rep("33"), signPublicKey: rep("44"), kemPublicKey: rep("55"),
            keyEpoch: 0, deviceEpoch: 7)
        XCTAssertEqual(hex(payload), "543ba0d195c857628b5279468c304239853d417550d69d7c0fe96887f91b51f3")
    }

    /// The credential core pins for the SDK verifies here, field for field.
    func testVerifiesTheCredentialCorePins() throws {
        let cert = try DeviceCertificates.verify(coreSdkCredential)
        XCTAssertEqual(cert.rootPublicKey, "ed6a47a39da869b5446155e40b2d93f1e3f0167be26732bae7a3ef9d8e3a3fd3")
        XCTAssertEqual(cert.kemPublicKey, rep("3a"))
        XCTAssertEqual(cert.keyEpoch, 0)
        XCTAssertEqual(cert.deviceEpoch, 0)
        XCTAssertEqual(cert.account, try DeviceCertificates.account(forRootPublicKey: cert.rootPublicKey))
        XCTAssertEqual(cert.signPublicKey, hex(try Ed25519.publicKey(seed: bytes(rep("6d")))))
        XCTAssertTrue(cert.device.hasPrefix(rep("a1", 16)))
    }

    /// Certifying with core's fixture inputs reproduces core's bytes up to the
    /// (randomized) signature, and the signature verifies.
    func testCertifyReproducesCoreLayout() throws {
        let rootSeed = bytes(rep("5c"))
        let account = try DeviceCertificates.account(forRootPublicKey: hex(try Ed25519.publicKey(seed: rootSeed)))
        let device = try DeviceCertificates.mintDeviceId(account: account, nonce: Data(repeating: 0xA1, count: 16))
        let credential = try DeviceCertificates.certify(
            rootSeed: rootSeed, device: device, signPublicKey: hex(try Ed25519.publicKey(seed: bytes(rep("6d")))),
            kemPublicKey: rep("3a"))
        XCTAssertEqual(credential.count, 474)
        XCTAssertEqual(String(credential.prefix(346)), String(coreSdkCredential.prefix(346)))
        XCTAssertNoThrow(try DeviceCertificates.verify(credential))
    }

    func testRefusesTamperedCredentials() throws {
        let good = coreSdkCredential
        // Re-pointed at another account.
        let repointed = String(good.prefix(74)) + rep("ff") + String(good.dropFirst(138))
        XCTAssertThrowsError(try DeviceCertificates.verify(repointed)) {
            XCTAssertTrue($0.localizedDescription.contains("re-pointed at another account"))
        }
        // Wrong genesis version.
        XCTAssertThrowsError(try DeviceCertificates.parse("01" + good.dropFirst(2))) {
            XCTAssertTrue($0.localizedDescription.contains("genesis version 1"))
        }
        // A handoff chain.
        let chained = String(good.prefix(66)) + "01000000" + String(good.dropFirst(74))
        XCTAssertThrowsError(try DeviceCertificates.parse(chained)) {
            XCTAssertTrue($0.localizedDescription.contains("root chain"))
        }
        // Truncated.
        XCTAssertThrowsError(try DeviceCertificates.parse(String(good.prefix(200)))) {
            XCTAssertTrue($0.localizedDescription.contains("474 hex characters"))
        }
        // A bad signature (last byte flipped).
        let badSig = String(good.dropLast(2)) + "01"
        XCTAssertThrowsError(try DeviceCertificates.verify(badSig)) {
            XCTAssertTrue($0.localizedDescription.contains("did not sign"))
        }
    }

    func testRefusesADeviceMintedForAnotherAccount() throws {
        let rootSeed = bytes(rep("77"))
        let device = try DeviceCertificates.mintDeviceId(account: rep("11"), nonce: Data(repeating: 0x33, count: 16))
        let credential = try DeviceCertificates.certify(
            rootSeed: rootSeed, device: device, signPublicKey: rep("44"), kemPublicKey: rep("55"), deviceEpoch: 7)
        XCTAssertThrowsError(try DeviceCertificates.verify(credential)) {
            XCTAssertTrue($0.localizedDescription.contains("not minted for account"))
        }
    }

    // MARK: - Routing proof (mero-js routing-proof.test.ts; MDMA fixture)

    private let routingCredential =
        "02d2fa6fe39efba7493f76ad6efc0e7996d831eb1a0ce6fda707397fe2c012c6060000000038701bbfdcbc1c30a0674e5e374a051b"
        + "d22d22fffd1059be29148ce1f2c227526c23496a85d5a2d25942c3196928d927e0074d01f73688cfd18c1943318ee66c236a9351"
        + "4a84577e9324eda015da3a8fb280b54a534d93ca2ab70f1eb5c77ed493e7d2ea8a91f18655f5c52a00ed0185d5cf4d45a27aa66b39"
        + "ad3f2d41e6876a000000000100000093449921849d2388e7281f85c7382f6c8f1da95a7246ef17698428a4e9388541c8712acbaf35"
        + "34ff6efcc89da0ff3c88534eb08537838dccd364743ce7ffd90a"
    private let routingSecret = "ef26085f1651bd1f4bba0832bf981c93cc00de33a037fb432b49b5fd4d552c88"
    private let routingSignature =
        "h5qmCVwG9B8Kgi1Fb0ipYgtQr6BsKM/MCPJfjpaR9UfmO+xDe3asjzvHvFraP/Ph5At9i2+ST2hGY9bTH8CyDQ=="

    /// MDMA's own signature verifies over `DOMAIN ‖ nonce` as built here.
    func testRoutingProofMessageIsTheOneMDMAVerifies() throws {
        let publicKey = try Ed25519.publicKey(seed: bytes(routingSecret))
        let message = Data("calimero.mdma.routing-read.v1\u{0}".utf8) + Data("test-nonce-abc".utf8)
        XCTAssertTrue(
            Ed25519.verify(publicKey: publicKey, signature: Data(base64Encoded: routingSignature)!, message: message))

        let ours = try CloudClient.signRoutingChallenge(nonce: "test-nonce-abc", deviceSecret: bytes(routingSecret))
        XCTAssertTrue(Ed25519.verify(publicKey: publicKey, signature: Data(base64Encoded: ours)!, message: message))
        // The fixture credential certifies exactly that device key.
        XCTAssertEqual(try DeviceCertificates.parse(routingCredential).signPublicKey, hex(publicKey))
    }

    func testRoutingProofSignsTheNonceNotAHashOfIt() throws {
        let publicKey = try Ed25519.publicKey(seed: bytes(routingSecret))
        let other = Data("calimero.mdma.routing-read.v1\u{0}".utf8) + Data("test-nonce-abd".utf8)
        XCTAssertFalse(
            Ed25519.verify(publicKey: publicKey, signature: Data(base64Encoded: routingSignature)!, message: other))
        XCTAssertThrowsError(try CloudClient.signRoutingChallenge(nonce: "n", deviceSecret: bytes("ef26")))
    }

    // MARK: - Login statement (core login_wire_fixture.rs via mero-js login.test.ts)

    private let loginDeviceKey = "fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618"

    private func loginParts(_ audience: LoginAudience) throws -> (preimage: Data, wireWithoutSig: String) {
        let deviceKey = bytes(loginDeviceKey)
        let preimage = try LoginStatement.preimage(
            node: rep("11"), audience: audience, challenge: rep("22"), sessionKey: rep("33"),
            deviceKey: deviceKey, issuedAt: 1_700_000_000, expiresAt: 1_700_000_300)
        let wire = try LoginStatement.wire(
            node: rep("11"), audience: audience, challenge: rep("22"), sessionKey: rep("33"),
            deviceKey: deviceKey, issuedAt: 1_700_000_000, expiresAt: 1_700_000_300, signature: Data(count: 64))
        return (preimage, String(wire.dropLast(128)))
    }

    func testLoginDeviceKeyDerivesFromCoresKey9() throws {
        XCTAssertEqual(hex(try Ed25519.publicKey(seed: bytes(rep("09")))), loginDeviceKey)
    }

    func testLoginStatementWebOriginMatchesCore() throws {
        let (preimage, wire) = try loginParts(.webOrigin("https://app.example:8443"))
        XCTAssertEqual(
            wire,
            rep("11") + "00" + "18000000" + "68747470733a2f2f6170702e6578616d706c653a38343433" + rep("22")
                + rep("33") + loginDeviceKey + "00f1536500000000" + "2cf2536500000000")
        let golden = bytes(
            "8302e61afe8f61c8471bc5f8ae9ff13cdd5b3e9bcd793cf8c46acb3ff9592aa4"
                + "37c1aae1b1ee9c9514f29b2340d13a547ea5e6cd4b4b65fbf09bafb55f4c7e00")
        XCTAssertTrue(Ed25519.verify(publicKey: bytes(loginDeviceKey), signature: golden, message: preimage))
    }

    func testLoginStatementCliTagCarriesNoLength() throws {
        let (preimage, wire) = try loginParts(.cli)
        XCTAssertEqual(
            wire,
            rep("11") + "02" + rep("22") + rep("33") + loginDeviceKey + "00f1536500000000" + "2cf2536500000000")
        let golden = bytes(
            "085b4ee049f7f268a35ec1bfdfe779b94f3bda66cbbb48937735f9ab10c0ef71"
                + "cad6f5bbb9afc4b2b87b5ee87d06284e3c5bc77a6c541c56e62aa65ace8fdb0b")
        XCTAssertTrue(Ed25519.verify(publicKey: bytes(loginDeviceKey), signature: golden, message: preimage))
    }

    func testLoginStatementCodeSigningIdMatchesCore() throws {
        let (preimage, wire) = try loginParts(.codeSigningId("dev.calimero.client"))
        XCTAssertEqual((wire.count + 128) / 2, 232)
        XCTAssertTrue(wire.contains("01130000006465762e63616c696d65726f2e636c69656e74"))
        let golden = bytes(
            "4aa7dd84d3d7960647d015a9a4483f2690ab5dc0abd4733634445edd3d8673a9"
                + "193ccc3b9251bbd1c5990a59fc02847d3191514f5725f074a0edfafbb3eeff0b")
        XCTAssertTrue(Ed25519.verify(publicKey: bytes(loginDeviceKey), signature: golden, message: preimage))
    }

    func testSignedLoginStatementVerifies() throws {
        let keys = try DeviceKeys(signSecret: bytes(rep("09")), kemSecret: bytes(rep("01")))
        let statement = try LoginStatement.sign(
            node: rep("11"), audience: .cli, challenge: rep("22"), sessionKey: rep("33"), issuedAt: 1_700_000_000,
            expiresAt: 1_700_000_300, keys: keys)
        let (preimage, wire) = try loginParts(.cli)
        XCTAssertEqual(String(statement.dropLast(128)), wire)
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: bytes(loginDeviceKey), signature: bytes(String(statement.suffix(128))), message: preimage))
    }

    // MARK: - Data-write warrant v2 (core warrant_wire_fixture.rs)

    private let warrantDeviceKey = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"

    private var warrantInput: Warrants.WarrantInput {
        Warrants.WarrantInput(
            context: rep("11"), authorAccount: rep("22"), executor: rep("33"), executorKey: rep("77"),
            releaseBytecodeId: rep("44"), releaseVersion: "1.0.0", method: "set", argsJson: ["key": "k", "value": "v"],
            nonce: 42, notAfter: 1_700_000_000, accountHeads: [rep("55")], governanceFloor: [rep("66")])
    }

    func testWarrantIntentHashMatchesCore() {
        XCTAssertEqual(
            hex(Warrants.intentHash(method: "set", argsJson: ["key": "k", "value": "v"])),
            "dc066cc8524c74dc21714174009df536376e3151f5b92f0a676defde599dbae5")
    }

    func testWarrantPreimageAndWireMatchCore() throws {
        XCTAssertEqual(hex(try Ed25519.publicKey(seed: bytes(rep("07")))), warrantDeviceKey)
        let preimage = try Warrants.warrantPreimage(warrantInput, devicePublicKey: bytes(warrantDeviceKey))
        XCTAssertEqual(hex(preimage), "f38e2c9eb7e78025f8797bb34168fe48da95a20320fc62fc2da41e3efd30607c")

        let golden =
            "e42f753e1a30657fe036b0c0a07030f3f6d92ea56749921c5a6ae07eb966cb50"
            + "1ed439f7a8007dfce0ccb6b5a8b94bdda9f48db9c84f181e9fbaa0d208726b02"
        XCTAssertTrue(Ed25519.verify(publicKey: bytes(warrantDeviceKey), signature: bytes(golden), message: preimage))

        let wire = try Warrants.warrantWire(
            warrantInput, devicePublicKey: bytes(warrantDeviceKey), signature: bytes(golden))
        let expected = [
            rep("11"), rep("22"), warrantDeviceKey, rep("33"), rep("77"), rep("44"),
            "05000000" + "312e302e30", "03000000" + "736574",
            "dc066cc8524c74dc21714174009df536376e3151f5b92f0a676defde599dbae5",
            "01000000" + rep("55"), "01000000" + rep("66"), "2a00000000000000", "00f1536500000000", golden,
        ].joined()
        XCTAssertEqual(wire, expected)
        XCTAssertEqual(wire.count, 784)
    }

    func testSignedWarrantVerifiesOverCorePreimage() throws {
        let keys = try DeviceKeys(signSecret: bytes(rep("07")), kemSecret: bytes(rep("01")))
        let warrant = try Warrants.signWarrant(warrantInput, keys: keys)
        XCTAssertEqual(warrant.count, 784)
        let preimage = bytes("f38e2c9eb7e78025f8797bb34168fe48da95a20320fc62fc2da41e3efd30607c")
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: bytes(warrantDeviceKey), signature: bytes(String(warrant.suffix(128))), message: preimage))
    }

    func testWarrantRefusesOverLimitInputsBeforeSigning() throws {
        var input = warrantInput
        input.accountHeads = Array(repeating: rep("55"), count: 65)
        XCTAssertThrowsError(try Warrants.warrantPreimage(input, devicePublicKey: bytes(warrantDeviceKey))) {
            XCTAssertTrue($0.localizedDescription.contains("65 heads, over the 64"))
        }
        input = warrantInput
        input.releaseVersion = String(repeating: "é", count: 129)
        XCTAssertThrowsError(try Warrants.warrantPreimage(input, devicePublicKey: bytes(warrantDeviceKey)))
    }

    // MARK: - Creation warrant (core creation_wire_fixture.rs)

    func testCreationWarrantMatchesCore() throws {
        let initHash = Warrants.creationInitHash(["name": "general"])
        XCTAssertEqual(hex(initHash), "074dc4be8c7abe685532a48947430edd0301b42f60222e715a834e723d2a055e")

        let input = Warrants.CreationInput(
            group: rep("11"), seed: rep("12"), authorAccount: rep("22"), executor: rep("33"), executorKey: rep("77"),
            applicationId: rep("44"), name: "general", initArgs: ["name": "general"], nonce: 42,
            notAfter: 1_700_000_000, accountHeads: [rep("55")], governanceFloor: [rep("66")])
        let preimage = try Warrants.creationPreimage(
            input, seed: bytes(rep("12")), devicePublicKey: bytes(warrantDeviceKey))
        XCTAssertEqual(hex(preimage), "7e1126b215a794e565bb59c630cb1a36e43590c4bd8f62c6111792f77c231598")

        let golden =
            "19103d73752d052f747911b4b36e423221d89d120bf6f4d32122d3c4fd1fb030"
            + "9add40f3f3b80a5e5d6fefa02de5f4d6bb914c85c5c8b10a3a0e3a0e22c08400"
        XCTAssertTrue(Ed25519.verify(publicKey: bytes(warrantDeviceKey), signature: bytes(golden), message: preimage))

        let wire = try Warrants.creationWire(
            input, seed: bytes(rep("12")), devicePublicKey: bytes(warrantDeviceKey), signature: bytes(golden))
        let expected = [
            rep("11"), rep("12"), rep("22"), warrantDeviceKey, rep("33"), rep("77"), rep("44"), "00",
            "01" + "07000000" + "67656e6572616c", hex(initHash), "01000000" + rep("55"), "01000000" + rep("66"),
            "2a00000000000000", "00f1536500000000", golden,
        ].joined()
        XCTAssertEqual(wire, expected)
        XCTAssertEqual(wire.count, 421 * 2)

        let keys = try DeviceKeys(signSecret: bytes(rep("07")), kemSecret: bytes(rep("01")))
        let (signed, seed) = try Warrants.signCreationWarrant(input, keys: keys)
        XCTAssertEqual(seed, rep("12"))
        XCTAssertEqual(String(signed.dropLast(128)), String(expected.dropLast(128)))
    }

    // MARK: - Governance warrant (core governance_wire_fixture.rs)

    func testGovernanceWarrantMatchesCore() throws {
        let op = Warrants.GovernanceOp(kind: .root, bytes: Data([1, 2, 3]))
        XCTAssertEqual(
            hex(Warrants.governanceOpHash(op)), "d6bc121f9fcf7b85bea94d356d620c14dd8e1ae5fa2317cbcfc2c486cf04dfb3")
        let input = Warrants.GovernanceInput(
            scope: rep("11"), op: op, authorAccount: rep("22"), executor: rep("33"), executorKey: rep("77"),
            nonce: 42, notAfter: 1_700_000_000, accountHeads: [rep("55")], governanceFloor: [rep("66")])
        let preimage = try Warrants.governancePreimage(input, devicePublicKey: bytes(warrantDeviceKey))
        XCTAssertEqual(hex(preimage), "b71a40cfbbe50e40d3423e8729a9ca8359e69f2762396922e6b314a971c5f720")

        let golden =
            "03ce6c011f565924099b2c776032a1cfe540d1c4c09fad0b470723f8ee76138d"
            + "1d685a20948edf4dee2901d3f9187e3363a16e3b141b0bc94553f5948becae07"
        XCTAssertTrue(Ed25519.verify(publicKey: bytes(warrantDeviceKey), signature: bytes(golden), message: preimage))
        let wire = try Warrants.governanceWire(
            input, devicePublicKey: bytes(warrantDeviceKey), signature: bytes(golden))
        XCTAssertEqual(
            wire,
            [
                rep("11"), "01", rep("22"), warrantDeviceKey, rep("33"), rep("77"),
                "d6bc121f9fcf7b85bea94d356d620c14dd8e1ae5fa2317cbcfc2c486cf04dfb3", "01000000" + rep("55"),
                "01000000" + rep("66"), "2a00000000000000", "00f1536500000000", golden,
            ].joined())
        XCTAssertEqual(wire.count, 345 * 2)
    }

    // MARK: - TEE key binding

    func testReportDataBindingOfAMockQuote() throws {
        let nodeKey = bytes(rep("ab"))
        let nonce = bytes(rep("cd"))
        let quote = Data("MOCK_TDX_QUOTE_V1".utf8) + nonce + RelayNodeKey.keyBinding(nodeKey)
        let (reportData, mock) = try RelayNodeKey.reportData(of: quote)
        XCTAssertTrue(mock)
        XCTAssertEqual(reportData.prefix(32), nonce)
        XCTAssertEqual(
            RelayNodeKey.keyBinding(nodeKey),
            sha256(Data("calimero.tee-attest.key-binding.v1".utf8) + Data(count: 32) + nodeKey))
        XCTAssertThrowsError(try RelayNodeKey.reportData(of: Data(count: 10)))
    }
}
