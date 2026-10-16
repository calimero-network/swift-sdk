import XCTest

@testable import MeroKit

/// Owner-op proofs, pinned byte for byte to core (port of mero-js
/// `owner-op.test.ts`).
///
/// Every constant is core's own output: `crates/account/src/tests/owner_op.rs`
/// and `root_guarded_vectors_are_stable` in
/// `crates/governance-types/src/tests.rs`. Core and WebCrypto sign Ed25519
/// deterministically and CryptoKit does not, so a whole proof is compared up
/// to its last 64 bytes, its signature is verified, and core's pinned
/// signature is verified against the payload computed here.
final class OwnerOpTests: XCTestCase {
    /// core's test root: `PrivateKey::from([7; 32])`.
    private static let root = String(repeating: "07", count: 32)
    private static let rootPublicKey = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"
    /// The account that root owns.
    private static let account = "9f9d3474c108b0bc7809ba35b5434980dd5b34f4a5042bdbb4de5519102324fb"
    private static let namespace = String(repeating: "11", count: 32)
    private static let group = String(repeating: "22", count: 32)
    private static let someone = String(repeating: "44", count: 32)

    /// core signs over arbitrary op bytes in its own test, so the op is hand-built.
    private static let handBuilt = OwnerOp(kind: .transferOwnership, plane: .group, bytes: Data("transfer to bob".utf8))

    private static let wholeProof =
        "02ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d2"
        + "2c000000009f9d3474c108b0bc7809ba35b5434980dd5b34f4a5042bdbb4de55"
        + "19102324fb111111111111111111111111111111111111111111111111111111"
        + "1111111111222222222222222222222222222222222222222222222222222222"
        + "222222222200350519af50455451fe2a1f181ec2f4c5363104f168055c6e9088"
        + "c5a5b65384df030000000000000000000000c62ebe7140bdffe975203603a4dc"
        + "27d4ced893a0e337698479885822deccf5ea97f1d4efdf071656a5ea50cc4446"
        + "abbb1a2f2a2e6720b8a1f2ac416bbf32020f"

    private static let guardedTransfer =
        "2a15444444444444444444444444444444444444444444444444444444444444"
        + "444402ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea6914"
        + "46d22c000000009f9d3474c108b0bc7809ba35b5434980dd5b34f4a5042bdbb4"
        + "de5519102324fb11111111111111111111111111111111111111111111111111"
        + "1111111111111122222222222222222222222222222222222222222222222222"
        + "2222222222222200a8d53a53c6d1007d055fbfd972aa7a99b27d5a816defdf82"
        + "6d49d1b0799b2c8f050000000000000000000000d9fefff69e034d07a996f2f0"
        + "dac5052865a93a780b58f935b3ff7a509ab88ed1f8171ee9c65b2b66a946ec53"
        + "d8aba76d53c4fd41553973d2fc87a05215f09502"

    /// The hex up to its trailing 64-byte signature, and that signature.
    private func split(_ hex: String) -> (body: String, signature: Data) {
        let body = String(hex.dropLast(128))
        return (body, try! Hex.decodeUnsized(String(hex.suffix(128)), label: "signature"))
    }

    private func transferPayload(digest: Data, counter: UInt64) throws -> Data {
        try ownerOpSigningPayload(
            account: Self.account, namespaceId: Self.namespace, groupId: Self.group, kind: .transferOwnership,
            opDigest: digest, counter: counter, keyEpoch: 0)
    }

    // MARK: - OwnerOpAuthorization

    func testKindBytesAreCoresDiscriminants() {
        XCTAssertEqual(OwnerOpKind.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(OwnerOpKind.groupDelete.ownerOnly)
        XCTAssertFalse(OwnerOpKind.teeAdmissionPolicy.ownerOnly)
    }

    func testDigestsTheOpUnderTheBodyDomain() {
        XCTAssertEqual(
            Hex.encode(ownerOpDigest(Self.handBuilt.bytes)),
            "350519af50455451fe2a1f181ec2f4c5363104f168055c6e9088c5a5b65384df")
    }

    func testSigningPayloadIsCores() throws {
        let payload = try transferPayload(digest: ownerOpDigest(Self.handBuilt.bytes), counter: 3)
        XCTAssertEqual(Hex.encode(payload), "a0855fcab12a8f8000345a0f25658f87d7650da170c50924be55fa780ca345a8")
        // core's own signature over it verifies against what is computed here.
        let pinned = split(Self.wholeProof).signature
        let rootKey = try Hex.decode(Self.rootPublicKey, label: "root", bytes: 32)
        XCTAssertTrue(Ed25519.verify(publicKey: rootKey, signature: pinned, message: payload))
    }

    func testEncodesTheWholeProofAsCoreDoes() async throws {
        let proof = try await signOwnerOpProof(
            OwnerOpProofInput(
                rootSecret: Self.root, namespaceId: Self.namespace, groupId: Self.group, op: Self.handBuilt,
                counter: 3))
        XCTAssertEqual(proof.count, Self.wholeProof.count)
        XCTAssertEqual(split(proof).body, split(Self.wholeProof).body)
        let payload = try transferPayload(digest: ownerOpDigest(Self.handBuilt.bytes), counter: 3)
        let rootKey = try Hex.decode(Self.rootPublicKey, label: "root", bytes: 32)
        XCTAssertTrue(Ed25519.verify(publicKey: rootKey, signature: split(proof).signature, message: payload))
    }

    func testSignsTheSameProofThroughASigner() async throws {
        let signer = try signerFromSecret(Self.root, label: "rootSecret")
        let proof = try await signOwnerOpProof(
            OwnerOpProofInput(
                root: .signer(signer), namespaceId: Self.namespace, groupId: Self.group, op: Self.handBuilt,
                counter: 3))
        XCTAssertEqual(split(proof).body, split(Self.wholeProof).body)
    }

    func testRefusesAKeyEpochItsChainCannotReach() async {
        do {
            _ = try await signOwnerOpProof(
                OwnerOpProofInput(
                    rootSecret: Self.root, namespaceId: Self.namespace, groupId: Self.group, op: Self.handBuilt,
                    counter: 0, keyEpoch: 1))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs 1 handoffs"), "\(error)")
        }
    }

    func testRefusesAHandoffOfTheWrongSize() async {
        do {
            _ = try await signOwnerOpProof(
                OwnerOpProofInput(
                    rootSecret: Self.root, namespaceId: Self.namespace, groupId: Self.group, op: Self.handBuilt,
                    counter: 0, chain: ["abcd"]))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("132-byte RootKeyHandoff"), "\(error)")
        }
    }

    // MARK: - GroupOp / RootOp encoders

    func testEncodesATransferAndItsRootGuardedWrapperAsCoreDoes() async throws {
        let transfer = try transferOwnershipOp(Self.someone)
        XCTAssertEqual(
            Hex.encode(ownerOpDigest(transfer.bytes)),
            "a8d53a53c6d1007d055fbfd972aa7a99b27d5a816defdf826d49d1b0799b2c8f")
        let proof = try await signOwnerOpProof(
            OwnerOpProofInput(
                rootSecret: Self.root, namespaceId: Self.namespace, groupId: Self.group, op: transfer, counter: 5))
        let guarded = Hex.encode(try rootGuardedOpBytes(transfer, rootProof: proof))
        XCTAssertEqual(split(guarded).body, split(Self.guardedTransfer).body)
        // core's pinned signature is over the payload computed here.
        let payload = try transferPayload(digest: ownerOpDigest(transfer.bytes), counter: 5)
        let rootKey = try Hex.decode(Self.rootPublicKey, label: "root", bytes: 32)
        XCTAssertTrue(
            Ed25519.verify(publicKey: rootKey, signature: split(Self.guardedTransfer).signature, message: payload))
    }

    func testEncodesAnAdminChangeAsARootOp() throws {
        let op = try adminChangedOp(Self.someone)
        XCTAssertEqual(op.plane, .root)
        XCTAssertEqual(
            Hex.encode(ownerOpDigest(op.bytes)), "bf73aaf8507327573528f38fdf5b003399a4773a7272539548188bc844d8a598")
        let wrapped = try rootGuardedOpBytes(op, rootProof: "ab")
        XCTAssertEqual(wrapped.first, 12)
    }

    func testEncodesTheTeePoliciesAndTheDeletionAsCoreDoes() {
        XCTAssertEqual(Hex.encode(teeAuthoringPolicyOp(["aa"]).bytes), "2101000000020000006161")
        let admission = teeAdmissionPolicyOp(
            TeeAdmissionPolicyOpInput(
                allowedMrtd: ["aa"], allowedRtmr0: [], allowedRtmr1: [], allowedRtmr2: [], allowedRtmr3: ["bb"],
                allowedTcbStatuses: ["UpToDate"], acceptMock: false, mode: .relay))
        XCTAssertEqual(
            Hex.encode(admission.bytes),
            "2501000000020000006161000000000000000000000000010000000200000062"
                + "6201000000080000005570546f446174650001")
        let release = teeReleaseAdmissionPolicyOp(
            TeeReleaseAdmissionPolicyOpInput(
                allowedProfiles: ["locked-read-only"], minReleaseVersion: "2.3.72", allowedTcbStatuses: [],
                acceptMock: true))
        XCTAssertEqual(
            Hex.encode(release.bytes),
            "2601000000100000006c6f636b65642d726561642d6f6e6c790106000000322e"
                + "332e3732000000000100")
        XCTAssertEqual(Hex.encode(groupDeleteOp().bytes), "0e")
    }

    func testAdmissionRequestBuildsTheOpTheNodeBuilds() throws {
        let measurement = SetTeeAdmissionPolicyRequest.measurement(
            allowedMrtd: ["aa"], allowedRtmr1: [], allowedRtmr2: [], allowedRtmr3: ["bb"],
            allowedTcbStatuses: ["UpToDate"], mode: .relay)
        XCTAssertEqual(
            Hex.encode(try measurement.ownerOp().bytes),
            "2501000000020000006161000000000000000000000000010000000200000062"
                + "6201000000080000005570546f446174650001")
        // The node strips its tag prefix before it builds the op.
        let release = SetTeeAdmissionPolicyRequest.signedRelease(
            SignedReleaseTeePolicy(allowedProfiles: ["locked-read-only"], minReleaseVersion: " mero-tee-v2.3.72"),
            allowedTcbStatuses: [], acceptMock: true)
        XCTAssertEqual(
            Hex.encode(try release.ownerOp().bytes),
            "2601000000100000006c6f636b65642d726561642d6f6e6c790106000000322e"
                + "332e3732000000000100")
    }
}
