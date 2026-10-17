import XCTest

@testable import MeroKit

/// Device scopes against core's own vectors (`DeviceScope::signing_payload`,
/// `DeviceScope::sign`, `borsh::to_vec(&AccountProof<DeviceScope>)`), ported
/// from mero-js `device-scope.test.ts`. The proof is compared up to its
/// signature (CryptoKit's Ed25519 is randomized), the signature is verified,
/// and core's pinned signature is verified against the payload computed here.
final class DeviceScopeTests: XCTestCase {
    private static let rootSecret = String(repeating: "5c", count: 32)
    private static let account = "ca999783990fd7f4ea0c192135f78c17ac77745bf580b2ed20fea455a8133845"
    private static let device = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1044305da225179a277d6d96e07ff21ea"
    private static let apps = [String(repeating: "11", count: 32), String(repeating: "22", count: 32)]

    private static let proofEmpty =
        "02ed6a47a39da869b5446155e40b2d93f1e3f0167be26732bae7a3ef9d8e3a3fd300000000"
        + "ca999783990fd7f4ea0c192135f78c17ac77745bf580b2ed20fea455a8133845"
        + "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1044305da225179a277d6d96e07ff21ea"
        + "000000000000000000000000"
        + "0d5f35a9d8060be917868b9c98efef2b8e3a3908c22c4faf17eb950da490fa64"
        + "c9a7c3c52c49944c2f624cbbf0d4c24a5faf1aa57ec3a8005279b94e738ebf05"
    private static let proofTwoApps =
        "02ed6a47a39da869b5446155e40b2d93f1e3f0167be26732bae7a3ef9d8e3a3fd300000000"
        + "ca999783990fd7f4ea0c192135f78c17ac77745bf580b2ed20fea455a8133845"
        + "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1044305da225179a277d6d96e07ff21ea"
        + "02000000"
        + "1111111111111111111111111111111111111111111111111111111111111111"
        + "2222222222222222222222222222222222222222222222222222222222222222"
        + "0700000000000000"
        + "ea5ac9c4c48801393fb2161892b2f267c65b23bf75fb33de559178644d2214c7"
        + "83ffdcb5e3c4ad4d310c235663c811b06762f829f0c7b9d87fcc6315bd590101"

    private var rootPublicKey: Data {
        try! Ed25519.publicKey(seed: Hex.decode(Self.rootSecret, label: "root", bytes: 32))
    }

    private func signature(of proof: String) -> Data {
        try! Hex.decodeUnsized(String(proof.suffix(128)), label: "signature")
    }

    func testDerivesTheAccountAndDeviceCoreDerives() throws {
        XCTAssertEqual(try DeviceCertificates.account(forRootPublicKey: Hex.encode(rootPublicKey)), Self.account)
        XCTAssertEqual(
            try DeviceCertificates.mintDeviceId(account: Self.account, nonce: Data(repeating: 0xA1, count: 16)),
            Self.device)
    }

    func testComputesThePayloadCoreSigns() throws {
        let empty = try deviceScopePayload(
            account: Self.account, device: Self.device, applications: [], scopeEpoch: 0, keyEpoch: 0)
        XCTAssertEqual(Hex.encode(empty), "99d56fe161047241aedab847a4325f64fe678ab4883460c502bec57a2ab11261")
        XCTAssertTrue(
            Ed25519.verify(publicKey: rootPublicKey, signature: signature(of: Self.proofEmpty), message: empty))
        let two = try deviceScopePayload(
            account: Self.account, device: Self.device, applications: Self.apps, scopeEpoch: 7, keyEpoch: 0)
        XCTAssertEqual(Hex.encode(two), "14ab8d9fa7c2cb5fd8957fcb8dcc02c7347b40c9871d73ab1dc3e6ed8a812476")
        XCTAssertTrue(
            Ed25519.verify(publicKey: rootPublicKey, signature: signature(of: Self.proofTwoApps), message: two))
    }

    func testEncodesTheProofCoreEncodesWithAndWithoutApplications() async throws {
        let empty = try await signDeviceScope(DeviceScopeInput(rootSecret: Self.rootSecret, device: Self.device))
        XCTAssertEqual(empty.dropLast(128), Self.proofEmpty.dropLast(128))
        let emptyPayload = try deviceScopePayload(
            account: Self.account, device: Self.device, applications: [], scopeEpoch: 0, keyEpoch: 0)
        XCTAssertTrue(Ed25519.verify(publicKey: rootPublicKey, signature: signature(of: empty), message: emptyPayload))

        let two = try await signDeviceScope(
            DeviceScopeInput(rootSecret: Self.rootSecret, device: Self.device, applications: Self.apps, scopeEpoch: 7))
        XCTAssertEqual(two.dropLast(128), Self.proofTwoApps.dropLast(128))
    }

    func testSignsTheSameBytesThroughASigner() async throws {
        let signer = try signerFromSecret(Self.rootSecret, label: "rootSecret")
        let proof = try await signDeviceScope(DeviceScopeInput(signer: signer, device: Self.device))
        XCTAssertEqual(proof.dropLast(128), Self.proofEmpty.dropLast(128))
    }

    func testRefusesBothASecretAndASigner() async throws {
        let signer = try signerFromSecret(Self.rootSecret, label: "rootSecret")
        do {
            _ = try await signDeviceScope(
                DeviceScopeInput(rootSecret: Self.rootSecret, signer: signer, device: Self.device))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not both"), "\(error)")
        }
    }
}
