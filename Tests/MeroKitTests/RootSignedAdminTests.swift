import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// The root-guarded owner ops with the proof minted by the SDK: each reads
/// the group's namespace and owner-op counter, builds the op the node will
/// build, and sends a proof that verifies over exactly those terms.
final class RootSignedAdminTests: XCTestCase {
    private static let root = String(repeating: "07", count: 32)
    private static let account = "9f9d3474c108b0bc7809ba35b5434980dd5b34f4a5042bdbb4de5519102324fb"
    private static let namespace = String(repeating: "11", count: 32)
    private static let group = String(repeating: "22", count: 32)
    private static let someone = String(repeating: "44", count: 32)

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A node whose groups all sit in ``namespace`` at owner-op counter 3.
    private func serve(counter: Int? = 3) -> ProofTransportLog {
        let log = ProofTransportLog()
        let counterField = counter.map { #","ownerOpCounter":\#($0)"# } ?? ""
        MockURLProtocol.setHandler { req in
            log.append(req)
            let json = ["Content-Type": "application/json"]
            guard req.httpMethod == "GET" else {
                return .init(status: 200, headers: json, body: Data(#"{"data":{}}"#.utf8))
            }
            let id = req.url?.lastPathComponent ?? ""
            let info =
                #"{"data":{"groupId":"\#(id)","appKey":"aa","targetApplicationId":"bb","memberCount":1,"#
                + #""contextCount":0,"defaultCapabilities":0,"subgroupVisibility":"open","#
                + #""namespaceId":"\#(Self.namespace)"\#(counterField)}}"#
            return .init(status: 200, headers: json, body: Data(info.utf8))
        }
        return log
    }

    private var admin: AdminApi {
        let base = URL(string: "https://node.test")!
        let http = URLSessionHttpClient(baseURL: base, session: MockURLProtocol.makeSession())
        return AdminApi(http: http)
    }

    private func rootProof(_ request: ProofTransportSeen?) throws -> String {
        let body = try XCTUnwrap(request?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["rootProof"] as? String)
    }

    /// The proof names `group` at counter 3 for `op`, and its signature verifies.
    private func assertProof(_ proof: String, op: OwnerOp, group: String) throws {
        let bytes = try Hex.decodeUnsized(proof, label: "proof")
        let digest = ownerOpDigest(op.bytes)
        var terms = Data()
        terms.append(try Hex.decode(Self.account, label: "account", bytes: 32))
        terms.append(try Hex.decode(Self.namespace, label: "namespace", bytes: 32))
        terms.append(try Hex.decode(group, label: "group", bytes: 32))
        terms.append(op.kind.rawValue)
        terms.append(digest)
        terms.append(LittleEndian.u64(3))
        terms.append(LittleEndian.u32(0))
        XCTAssertEqual(bytes.dropLast(64).suffix(terms.count), terms)
        let payload = try ownerOpSigningPayload(
            account: Self.account, namespaceId: Self.namespace, groupId: group, kind: op.kind, opDigest: digest,
            counter: 3, keyEpoch: 0)
        let rootKey = try Ed25519.publicKey(seed: try Hex.decode(Self.root, label: "root", bytes: 32))
        XCTAssertTrue(Ed25519.verify(publicKey: rootKey, signature: bytes.suffix(64), message: payload))
    }

    func testTransferOwnershipReadsTheCounterAndSignsTheTransfer() async throws {
        let log = serve()
        try await admin.transferOwnership(Self.group, newOwner: Self.someone, root: .secret(Self.root))
        XCTAssertEqual(log.requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(log.requests.first?.url, "https://node.test/admin-api/groups/\(Self.group)")
        XCTAssertTrue(log.requests.last?.url.hasSuffix("/groups/\(Self.group)/transfer-ownership") == true)
        try assertProof(try rootProof(log.requests.last), op: try transferOwnershipOp(Self.someone), group: Self.group)
    }

    func testAnAdminChangeNamesTheNamespaceRootAsItsGroup() async throws {
        let log = serve()
        let signer = try signerFromSecret(Self.root)
        try await admin.changeNamespaceAdmin(Self.namespace, newAdmin: Self.someone, root: .signer(signer))
        try assertProof(try rootProof(log.requests.last), op: try adminChangedOp(Self.someone), group: Self.namespace)
    }

    func testOwnerDeleteAndTheTeeAuthoringPolicySignTheirOps() async throws {
        var log = serve()
        try await admin.ownerDeleteGroup(Self.group, root: .secret(Self.root))
        try assertProof(try rootProof(log.requests.last), op: groupDeleteOp(), group: Self.group)

        log = serve()
        try await admin.setTeeAuthoringPolicy(Self.namespace, allowedMrtd: ["aa"], root: .secret(Self.root))
        try assertProof(try rootProof(log.requests.last), op: teeAuthoringPolicyOp(["aa"]), group: Self.namespace)

        log = serve()
        try await admin.disableTeeAuthoringPolicy(Self.namespace, root: .secret(Self.root))
        XCTAssertEqual(log.requests.last?.method, "DELETE")
        try assertProof(try rootProof(log.requests.last), op: teeAuthoringPolicyOp([]), group: Self.namespace)
    }

    func testTheAdmissionPolicyIsSignedOverTheOpTheNodeBuilds() async throws {
        let log = serve()
        let request = SetTeeAdmissionPolicyRequest.signedRelease(
            SignedReleaseTeePolicy(allowedProfiles: ["locked-read-only"], minReleaseVersion: "mero-tee-v2.3.72"),
            allowedTcbStatuses: [], acceptMock: true)
        try await admin.setTeeAdmissionPolicy(Self.namespace, request: request, root: .secret(Self.root))
        let op = teeReleaseAdmissionPolicyOp(
            TeeReleaseAdmissionPolicyOpInput(
                allowedProfiles: ["locked-read-only"], minReleaseVersion: "2.3.72", allowedTcbStatuses: [],
                acceptMock: true))
        try assertProof(try rootProof(log.requests.last), op: op, group: Self.namespace)
    }

    func testANodeWithoutACounterIsRefusedBeforeAnythingIsSigned() async {
        let log = serve(counter: nil)
        do {
            try await admin.ownerDeleteGroup(Self.group, root: .secret(Self.root))
            XCTFail("signed without a counter")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ownerOpCounter"), "\(error)")
        }
        XCTAssertEqual(log.requests.map(\.method), ["GET"])
    }

    func testLinkAccountDeviceSignsTheScope() async throws {
        let log = serve()
        _ = try? await admin.linkAccountDevice(
            Self.namespace, credential: "ab",
            scope: DeviceScopeInput(rootSecret: Self.root, device: Self.someone, applications: [Self.group]))
        let body = try XCTUnwrap(log.requests.last?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["credential"] as? String, "ab")
        let scope = try XCTUnwrap(json["scope"] as? String)
        // genesis (33) + empty chain (4) + account + device + 1 application + epochs + signature.
        XCTAssertEqual(scope.count, (33 + 4 + 32 + 32 + 4 + 32 + 4 + 4 + 64) * 2)
        XCTAssertTrue(log.requests.last?.url.hasSuffix("/namespaces/\(Self.namespace)/account/link-device") == true)
    }
}
