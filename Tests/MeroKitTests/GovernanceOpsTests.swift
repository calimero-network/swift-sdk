import MeroKitTestSupport
import XCTest

@testable import MeroKit

/// Governance op builders, namespace founding, invitations an account signs,
/// and the HA claim — against the golden vectors mero-js pins, which are core's
/// own (`crates/governance-types/src/tests.rs`: `delegated_governance_op_vectors_are_stable`,
/// `delegable_governance_op_vectors_for_non_rust_encoders_are_stable`,
/// `delegable_target_application_set_vector_is_stable`; core 0.11.0-rc.83).
///
/// CryptoKit's Ed25519 is randomized: signatures are verified, never compared;
/// preimages, hashes and wire layouts are compared byte for byte.
final class GovernanceOpsTests: XCTestCase {
    private func hex(_ data: Data) -> String { Hex.encode(data) }
    private func rep(_ byte: String, _ count: Int = 32) -> String { String(repeating: byte, count: count) }

    // MARK: - Op vectors (mero-js governance-op-vectors.test.ts)

    private var acct: String { rep("44") }
    private var grp: String { rep("55") }
    private var par: String { rep("11") }
    private var ctx: String { rep("66") }
    /// core's fixed-byte AccountProof<DeviceCert> fixture (layout only).
    private var layoutCredential: String {
        "02" + rep("77") + "00000000" + rep("44") + rep("88") + rep("99") + rep("aa") + "00000000" + "01000000"
            + rep("bb", 64)
    }

    private func check(
        _ name: String, _ op: Warrants.GovernanceOp, _ bytes: String, _ opHash: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(hex(op.bytes), bytes, name, file: file, line: line)
        XCTAssertEqual(hex(Warrants.governanceOpHash(op)), opHash, name, file: file, line: line)
    }

    func testDelegableOpsMatchCoresPinnedVectors() throws {
        let data = ["topic": "rust"]
        check(
            "MemberRemoved", try GovernanceOps.memberRemoved(acct), "02" + acct + rep("00") + "00000000",
            "fdc08345155864f7a9481194c7f12b313994b1a95955ee0969422f0147ab2779")
        check(
            "MemberLeft", try GovernanceOps.memberLeft(acct), "03" + acct + rep("00") + "00000000",
            "05392aaa36e0e7d08fc9150536d1c9906cd6f5445b0afb6cedec2f03938c6b3d")
        check(
            "MemberRoleSet Admin", try GovernanceOps.memberRoleSet(acct, role: .admin), "04" + acct + "00",
            "79a70a143fb990f2f92478812b0c142ec8e94a75769d415b3e3bbf769168b2bb")
        check(
            "MemberRoleSet ReadOnly", try GovernanceOps.memberRoleSet(acct, role: .readOnly), "04" + acct + "02",
            "843978d9ed8c38856a33df18ed3ca9a1e60800b3c0985949ce0db831dd57c75d")
        check(
            "MemberCapabilitySet 1", try GovernanceOps.memberCapabilitySet(acct, capabilities: 1),
            "05" + acct + "01000000",
            "4266c138e10d5aa8837fcb1d1e7bb81b88c215d4ddea5f7ec413c7a87c995758")
        check(
            "MemberCapabilitySet 231", try GovernanceOps.memberCapabilitySet(acct, capabilities: 231),
            "05" + acct + "e7000000", "9225ce03739ea127393321b4b517b5badd05290131e865bd6bb2a5a34af57287")
        check(
            "DefaultCapabilitiesSet 231", try GovernanceOps.defaultCapabilitiesSet(231), "06e7000000",
            "0bc00f5f7627b34a104b6aa059887c2cf30f59f468711462176f35592fcf95fd")
        check(
            "ContextDetached", try GovernanceOps.contextDetached(ctx), "09" + ctx,
            "363e49ed17f870151deed61caa14f493fad3f4e1d9c4781f35b21b833a4f2bf3")
        check(
            "Visibility open", GovernanceOps.subgroupVisibilitySet(.open), "0a00",
            "99d379e4656d5711132d0d44491446ab93480b6ad58bc216aba9358bf693d57b")
        check(
            "Visibility restricted", GovernanceOps.subgroupVisibilitySet(.restricted), "0a01",
            "42b90a291fb2b5e5d8a5da5a1096facde5d34c2d3ad92903507e1709434020a1")
        check(
            "GroupMetadataSet Some", GovernanceOps.groupMetadataSet(name: "general", data: data),
            "0b010700000067656e6572616c0100000005000000746f7069630400000072757374",
            "2d789be70265d50780fc8cac9b1c3ff847352fccd2ad36e76ffdc464134d4bc9")
        check(
            "GroupMetadataSet None", GovernanceOps.groupMetadataSet(), "0b0000000000",
            "4fc9cfd6f2af5690ff47fc685c8ef1408c2c49f41aac2a2a8151223e5dfe2e1d")
        check(
            "MemberMetadataSet Some", try GovernanceOps.memberMetadataSet(acct, name: "alice", data: data),
            "0c" + acct + "0105000000616c6963650100000005000000746f7069630400000072757374",
            "58a5290db3c57d34bb40679071c4739eff0ff81e0e728ff98d707ed570c1eeab")
        check(
            "MemberMetadataSet None", try GovernanceOps.memberMetadataSet(acct), "0c" + acct + "0000000000",
            "d682f73eacf1b2b04aa85e1abde1b37c5e16399a5f41b2d385581a0c401db32e")
        check(
            "ContextMetadataSet Some", try GovernanceOps.contextMetadataSet(ctx, name: "general", data: data),
            "0d" + ctx + "010700000067656e6572616c0100000005000000746f7069630400000072757374",
            "81768a47949bec9245da34acbfc9d90ff8152e65df38026e99691f2d0f4e3f86")
        check(
            "ContextMetadataSet None", try GovernanceOps.contextMetadataSet(ctx), "0d" + ctx + "0000000000",
            "4de9794df28cbcfb3fae1c960eaf4a8244b5f415a1a7506b963ec82c1bf1033d")
        check(
            "ContextCapabilityGranted",
            try GovernanceOps.contextCapabilityGranted(contextId: ctx, member: acct, capability: 1),
            "10" + ctx + acct + "01", "af5093cfd553f9431d4c2c6eacc8c5ac90c709d520122fa5420982d2594f0ff1")
        check(
            "ContextCapabilityRevoked",
            try GovernanceOps.contextCapabilityRevoked(contextId: ctx, member: acct, capability: 231),
            "11" + ctx + acct + "e7", "1ba014f559da55169bdcb663f3cd79b5b6519aecf7a09dc5976b9c28e3cd94fd")
        check(
            "GroupReparented", try GovernanceOps.groupReparented(childGroupId: grp, newParentId: par), "01" + grp + par,
            "a52c81b6b15c534a10db72373a4213f0ea75c7b99dbea1c93d510169b804d427")
        check(
            "GroupDeleted", try GovernanceOps.groupDeleted(grp), "02" + grp + "0000000000000000",
            "b2dd53fba1c8b83ef704de1fcc868cc68d4f74cd2a54cd1db4998213500fddd0")
        check(
            "MemberJoinedOpen",
            try GovernanceOps.memberJoinedOpen(member: acct, groupId: grp, credential: layoutCredential),
            "07" + acct + grp + layoutCredential, "b9642890aae8b920d6bd9376e532423b6074becd9eb568843b2de025fd294192")
    }

    func testMemberAddedGroupCreatedAndSubgroupIdMatchCore() throws {
        let added = try GovernanceOps.memberAdded(acct, role: .member)
        XCTAssertEqual(added.kind, .group)
        check(
            "MemberAdded", added, "01" + acct + "01", "c48dce4ba9da20980a86832b133e7040ec67c293987c0f131140291a71041cd6"
        )

        let created = try GovernanceOps.groupCreated(
            groupId: rep("55"), parentId: rep("11"), restricted: true, admin: rep("22"), salt: rep("33"))
        XCTAssertEqual(created.kind, .root)
        check(
            "GroupCreated", created, "00" + rep("55") + rep("11") + "01" + rep("22") + rep("33"),
            "3a30eacf28687109de2b63b649cb0d8a532f344212066897547f52a416a1be0e")

        // core's `created_subgroup_id_has_a_known_answer`.
        XCTAssertEqual(
            try GovernanceOps.createdSubgroupId(
                admin: rep("11"), parentId: rep("33"), restricted: true, salt: rep("22")),
            "6c949a0f0e0c3c55310223f4cd03f888b6e84c7e963f9171a5639fc54ea93b1a")
        let fresh = try GovernanceOps.subgroupCreation(parentId: rep("11"), restricted: false, admin: rep("22"))
        XCTAssertEqual(
            fresh.groupId,
            try GovernanceOps.createdSubgroupId(
                admin: rep("22"), parentId: rep("11"), restricted: false, salt: fresh.salt))
        XCTAssertEqual(hex(fresh.op.bytes), "00" + fresh.groupId + rep("11") + "00" + rep("22") + fresh.salt)
    }

    func testTargetApplicationSetMatchesCoresVector() throws {
        let op = try GovernanceOps.targetApplicationSet(
            applicationId: rep("88"), package: "com.example.app", version: "1.2.3")
        XCTAssertEqual(op.kind, .group)
        check(
            "TargetApplicationSet", op,
            "07" + rep("00") + rep("88") + "0f000000636f6d2e6578616d706c652e61707005000000312e322e33",
            "904984c8f39e4172ea8864a65511faead68baa76af18d31e1d442a0b9fcb656b")
        XCTAssertThrowsError(
            try GovernanceOps.targetApplicationSet(applicationId: rep("88"), package: "", version: "1"))
        XCTAssertThrowsError(
            try GovernanceOps.targetApplicationSet(applicationId: rep("88"), package: "p", version: ""))
    }

    func testGuards() throws {
        XCTAssertThrowsError(try GovernanceOps.defaultCapabilitiesSet(512)) {
            XCTAssertTrue("\($0.localizedDescription)".contains("CAN_AUTHOR_ON_BEHALF"))
        }
        XCTAssertThrowsError(try GovernanceOps.memberCapabilitySet(acct, capabilities: 512))
        XCTAssertEqual(hex(try GovernanceOps.defaultCapabilitiesSet(0xffff_fdff).bytes), "06fffdffff")
        XCTAssertThrowsError(try GovernanceOps.contextCapabilityGranted(contextId: ctx, member: acct, capability: 0))
        XCTAssertThrowsError(try GovernanceOps.memberAdded(rep("44", 62), role: .member))
        // BTreeMap order is by key bytes.
        XCTAssertEqual(
            GovernanceOps.groupMetadataSet(data: ["b": "2", "a": "1"]),
            GovernanceOps.groupMetadataSet(data: ["a": "1", "b": "2"]))
    }

    // MARK: - Namespace genesis (mero-js governance-warrant.test.ts, from core's crates)

    private let genesisCredential =
        "02c853ad0f0cd2b619aea92ceec4fd56a24d6499d584ce79257e45cfd8139b60"
        + "a700000000161e0b241fdac4166b442a199cb689e0b438938bbb30e31baca7f1"
        + "403095feff333333333333333333333333333333333333333333333333333333"
        + "3333333333ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea"
        + "691446d22c555555555555555555555555555555555555555555555555555555"
        + "55555555550000000001000000292c12a66bae1c2c32f62455037246da6f84b2"
        + "4345a590ef3db4bf15670afc5ea47b30ec242827257fb2f33660dda6f081b0ba"
        + "253c0f3d02014cbabeb5c9a70f"
    private let founder = "161e0b241fdac4166b442a199cb689e0b438938bbb30e31baca7f1403095feff"
    private let genesisWarrant =
        "107c1c0ef0ca701608f0ec814572775e41197ba131b1263931d5789cf76bef69"
        + "01161e0b241fdac4166b442a199cb689e0b438938bbb30e31baca7f1403095fe"
        + "ffea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d2"
        + "2c33333333333333333333333333333333333333333333333333333333333333"
        + "3377777777777777777777777777777777777777777777777777777777777777"
        + "77eec5a1ad4daa778659cbde6395cd6cd5839a5ac97966e88f4affdd88b83137"
        + "6e0000000000000000010000000000000000f15365000000001087244bdc6743"
        + "869f074896b30a22be0a19c4c2ed999454aff7c7f479d7f9bdab2eda608d8621"
        + "d61091c0fd79dec6d923cdc1d1d581733be3d51134e00f480e"

    func testFoundedNamespaceIdMatchesCore() throws {
        XCTAssertEqual(
            try GovernanceOps.foundedNamespaceId(founder: founder, salt: rep("5c")),
            "107c1c0ef0ca701608f0ec814572775e41197ba131b1263931d5789cf76bef69")
        // core's `founded_namespace_id_has_a_known_answer`.
        XCTAssertEqual(
            try GovernanceOps.foundedNamespaceId(founder: rep("11"), salt: rep("22")),
            "35f5e77cc3c7cdb18eef50f1ea2808f27069dd25143e935994fcd58b3876c0bd")
    }

    func testGenesisOpAndWarrantMatchCore() throws {
        let op = try GovernanceOps.namespaceCreated(founder: founder, credential: genesisCredential, salt: rep("5c"))
        XCTAssertEqual(op.kind, .root)
        XCTAssertEqual(op.bytes.count, 302)
        XCTAssertEqual(hex(op.bytes), "09" + founder + genesisCredential + rep("5c"))
        XCTAssertEqual(
            hex(Warrants.governanceOpHash(op)), "eec5a1ad4daa778659cbde6395cd6cd5839a5ac97966e88f4affdd88b831376e")

        let keys = try DeviceKeys(signSecret: Data(repeating: 0x07, count: 32), kemSecret: Data(count: 32))
        let devicePk = try Ed25519.publicKey(seed: keys.signSecret)
        XCTAssertEqual(hex(devicePk), "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c")
        let input = Warrants.GovernanceInput(
            scope: try GovernanceOps.foundedNamespaceId(founder: founder, salt: rep("5c")), op: op,
            authorAccount: founder, executor: rep("33"), executorKey: rep("77"), nonce: 1, notAfter: 1_700_000_000)
        let golden = try Hex.decodeUnsized(genesisWarrant, label: "warrant")
        let goldenSignature = golden.suffix(64)
        // Core's (deterministic) signature verifies over the preimage computed here...
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: devicePk, signature: goldenSignature,
                message: try Warrants.governancePreimage(input, devicePublicKey: devicePk)))
        // ...and with it the wire is core's, byte for byte.
        XCTAssertEqual(
            try Warrants.governanceWire(input, devicePublicKey: devicePk, signature: goldenSignature), genesisWarrant)
        // Ours (randomized) verifies too.
        let ours = try Hex.decodeUnsized(try Warrants.signGovernanceWarrant(input, keys: keys), label: "w")
        XCTAssertEqual(ours.prefix(ours.count - 64), golden.prefix(golden.count - 64))
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: devicePk, signature: ours.suffix(64),
                message: try Warrants.governancePreimage(input, devicePublicKey: devicePk)))

        XCTAssertThrowsError(try GovernanceOps.namespaceCreated(founder: founder, credential: "", salt: rep("5c")))
        XCTAssertThrowsError(
            try GovernanceOps.namespaceCreated(founder: founder, credential: genesisCredential, salt: "5c"))
    }

    // MARK: - Invitations (mero-js invitation.test.ts)

    private let devicePk = "8b237d788e8eaaef550c6d125823fa45f1fd5fc29b2c88bdf871119471fc1312"
    private let coreBorsh =
        "8b237d788e8eaaef550c6d125823fa45f1fd5fc29b2c88bdf871119471fc13124242424242424242424242424242424242424242424242"
        + "424242424242424242008db26a0000000007070707070707070707070707070707070707070707070707070707070707070102000000"
        + "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
        + "0b0b0b0b0b0b0b0b0b0b0b"
    private let coreHash = "0739d4d206f6dc3359ea7510766139b908a5b58e4d53552c62da72cea5c4af72"
    private let coreSig =
        "a9945492839aa130892dc8056fd1a4c882792a0c1426a68f6bd90fac7218ebb2086b505e2f9cbdeb4b7dd1c60199cd8d589a1c14a0c8"
        + "721bbb1331a20f0a7309"
    private var inviterKeys: DeviceKeys {
        try! DeviceKeys(signSecret: Data(repeating: 0x6D, count: 32), kemSecret: Data(count: 32))
    }

    private func signFixture(
        admitters: [String]? = nil, members: [GroupMember]? = nil
    ) throws
        -> SignedGroupOpenInvitation
    {
        try GroupInvitations.sign(
            groupId: rep("42"), inviterAccount: rep("CC"), keys: inviterKeys,
            admitters: admitters ?? [rep("0a"), rep("0b")], members: members, now: 1_790_000_000,
            nonce: Data(repeating: 7, count: 32))
    }

    func testInvitationSignsTheBodyCoreSigns() throws {
        let signed = try signFixture()
        XCTAssertEqual(hex(try NamespaceOps.encodeGroupInvitation(signed.invitation)), coreBorsh)
        XCTAssertEqual(hex(try GroupInvitations.hash(signed.invitation)), coreHash)
        XCTAssertEqual(signed.inviterAccount, rep("cc"))
        XCTAssertEqual(hex(Data(signed.invitation.inviterIdentity.map { UInt8($0) })), devicePk)
        let pk = try Hex.decode(devicePk, label: "pk", bytes: 32)
        let hash = try Hex.decode(coreHash, label: "h", bytes: 32)
        XCTAssertTrue(
            Ed25519.verify(publicKey: pk, signature: try Hex.decode(coreSig, label: "s", bytes: 64), message: hash))
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: pk, signature: try Hex.decode(signed.inviterSignature, label: "s", bytes: 64), message: hash)
        )
        XCTAssertTrue(hex(try NamespaceOps.encodeSignedInvitation(signed)).hasPrefix(coreBorsh))
    }

    func testInvitationDefaultsAdmittersToAdminsAndRefusesBroadcast() throws {
        let members = [
            GroupMember(identity: rep("0B"), role: "Admin"), GroupMember(identity: rep("ff"), role: "Member"),
            GroupMember(identity: rep("0a"), role: "Admin"), GroupMember(identity: rep("0b"), role: "Admin"),
        ]
        let signed = try signFixture(admitters: [], members: members)
        XCTAssertEqual(hex(try NamespaceOps.encodeGroupInvitation(signed.invitation)), coreBorsh)
        XCTAssertThrowsError(try signFixture(admitters: [])) {
            XCTAssertTrue("\($0.localizedDescription)".contains("broadcast"))
        }
        XCTAssertThrowsError(
            try signFixture(admitters: [], members: [GroupMember(identity: rep("ff"), role: "Member")]))
        let short = try GroupInvitations.sign(
            groupId: rep("42"), inviterAccount: rep("cc"), keys: inviterKeys, admitters: [rep("0a")],
            validForSeconds: 10 * 86_400, now: 100)
        XCTAssertEqual(short.invitation.expirationTimestamp, 100 + GroupInvitations.maxValiditySeconds)
    }

    // MARK: - Application id (mero-js application-id.test.ts)

    func testApplicationIdForBundleMatchesMerod() {
        XCTAssertEqual(
            ApplicationRegistry.applicationIdForBundle(
                package: "com.calimero.kv-store", signerId: "did:key:z6MkoWkrrFjwC4FXQfyGwwcgTPvRoJZenMEVm9Z332bdkz6B"),
            "e810e86f443e8c1feb98bb83a266246478a34c75397a66a78bd5a790c6d72d0d")
        XCTAssertEqual(
            ApplicationRegistry.applicationIdForBundle(package: "com.calimero.café", signerId: "did:key:z6MkExample"),
            "cf9b180c7952ef0aa41fe73e9cb7ac2b4b19917099341e295534aa4a50861bd5")
        let picked = ApplicationRegistry.selectLatest([
            .init(appVersion: "0.0.9"), .init(appVersion: "0.0.41"), .init(appVersion: "1.0.0", yanked: true),
        ])
        XCTAssertEqual(picked?.appVersion, "0.0.41")
    }

    // MARK: - HA claim (mero-js enable-ha-as-account.test.ts)

    func testHaClaimPayloadOrderAndSignature() throws {
        let keys = inviterKeys
        let proof = try AccountHaClaim.sign(
            namespaceId: rep("AB"), accountId: rep("cd"), salt: rep("5c"), credential: "cred", keys: keys,
            relayURL: "https://relay.example/x", nowMs: 1_000, nonce: rep("01", 16))
        XCTAssertEqual(proof.kind, "account")
        let payload = try XCTUnwrap(Data(base64Encoded: proof.signedPayload))
        XCTAssertEqual(
            String(decoding: payload, as: UTF8.self),
            #"{"v":1,"audience":"mdma:enable-ha-namespace-as-account","group_id":"\#(rep("ab"))","account_id":"\#(rep("cd"))","salt":"\#(rep("5c"))","nonce":"\#(rep("01", 16))","issued_at_ms":1000,"expires_at_ms":61000,"relay_url":"https://relay.example/x"}"#
        )
        let signature = try XCTUnwrap(Data(base64Encoded: proof.signature))
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: try Ed25519.publicKey(seed: keys.signSecret), signature: signature,
                message: Data("calimero.mdma.account-ownership-claim.v1\u{0}".utf8) + payload))
        XCTAssertThrowsError(
            try AccountHaClaim.sign(
                namespaceId: rep("ab"), accountId: rep("cd"), salt: rep("5c"), credential: "c", keys: keys,
                ttlMs: 300_001))
    }

    // MARK: - Over the wire

    private var rig: CloudRig!
    private let relay = "https://relay.test"
    private let cloud = URL(string: "https://cloud.test")!
    private let wallet = TestWallet()
    private let keys = try! DeviceKeys(
        signSecret: Data(repeating: 0x07, count: 32), kemSecret: Data(repeating: 0x08, count: 32))

    override func setUp() {
        super.setUp()
        rig = CloudRig()
        rig.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        rig = nil
        super.tearDown()
    }

    func testEnableHaAsAccountPostsTheClaimAndNamesRefusals() async throws {
        let cb = wallet.approve(keys, state: nil)
        let ns = rep("ab")
        let path = "/api/cloud/accounts/\(cb.account)/namespaces/\(ns)/enable-ha"
        rig.on("POST", path, json: #"{"status":"enabled"}"#)
        let client = CloudClient(baseURL: cloud, session: MockURLProtocol.makeSession())
        try await client.enableHaAsAccount(
            namespaceId: ns.uppercased(), salt: rep("5c"), accountId: cb.account, credential: cb.credential, keys: keys,
            relayURL: relay)
        let body = try XCTUnwrap(rig.requests("POST", path).first?.json)
        XCTAssertEqual(body["ownership_proof"]?["kind"], "account")
        XCTAssertEqual(body["ownership_proof"]?["credential"]?.stringValue, cb.credential)
        XCTAssertNil(rig.requests("POST", path).first?.headers["authorization"])

        rig.on("POST", path, status: 409, json: #"{"detail":{"error":"account_not_linked"}}"#)
        do {
            try await client.enableHaAsAccount(
                namespaceId: ns, salt: rep("5c"), accountId: cb.account, credential: cb.credential, keys: keys)
            XCTFail("expected a refusal")
        } catch AccountError.haRefused(let code, let status, _) {
            XCTAssertEqual(code, "account_not_linked")
            XCTAssertEqual(status, 409)
        }
        rig.on("POST", path, status: 409, json: #"{"error":"something_else"}"#)
        do {
            try await client.enableHaAsAccount(
                namespaceId: ns, salt: rep("5c"), accountId: cb.account, credential: cb.credential, keys: keys)
            XCTFail("expected an HTTP error")
        } catch MeroError.http(let http) {
            XCTAssertEqual(http.status, 409)
        }
    }

    private func serveGovernance(_ group: String) {
        rig.on(
            "GET", "/admin-api/groups/\(group)/governance-intents",
            json:
                #"{"data":{"executorAccount":"\#(rep("33"))","executorKey":"\#(rep("77"))","groupId":"\#(group)","canActOnBehalf":true}}"#
        )
    }

    func testFoundNamespaceSignsTheGenesisThenSetsAppAndCapabilities() async throws {
        let cb = wallet.approve(keys, state: nil)
        let nonces = MemoryWarrantNonceStore()
        let client = RelayClient(
            relayURL: relay, authorAccount: cb.account, authorProof: cb.credential, keys: keys, nonces: nonces,
            session: MockURLProtocol.makeSession())
        let salt = rep("5c")
        let ns = try GovernanceOps.foundedNamespaceId(founder: cb.account, salt: salt)
        serveGovernance(ns)
        rig.on(
            "POST", "/admin-api/groups/\(ns)/governance-intents",
            json: #"{"data":{"groupId":"\#(ns)","teeEnabled":true}}"#)

        let founded = try await client.foundNamespace(
            executor: RelayExecutor(executorAccount: rep("33"), executorKey: rep("77")), salt: salt,
            defaultCapabilities: 231,
            application: FoundingApplication(applicationId: rep("88"), package: "com.example.app", version: "1.2.3"))
        XCTAssertEqual(founded.namespaceId, ns)
        XCTAssertEqual(founded.salt, salt)
        XCTAssertTrue(founded.teeEnabled)
        XCTAssertEqual(founded.applicationSet, true)
        XCTAssertEqual(founded.defaultCapabilitiesSet, true)

        let posts = rig.requests("POST", "/admin-api/groups/\(ns)/governance-intents").compactMap { $0.json }
        XCTAssertEqual(posts.count, 3)
        let genesis = try GovernanceOps.namespaceCreated(founder: cb.account, credential: cb.credential, salt: salt)
        XCTAssertEqual(posts[0]["op"]?.stringValue, Hex.encode(genesis.bytes))
        XCTAssertEqual(posts[0]["authorProof"]?.stringValue, cb.credential)
        XCTAssertTrue(posts[1]["op"]?.stringValue?.hasPrefix("07") == true, "the application first")
        XCTAssertEqual(posts[2]["op"], "06e7000000")
        // The genesis warrant is scoped to the derived id and signed by this device.
        let wire = try Hex.decodeUnsized(try XCTUnwrap(posts[0]["warrant"]?.stringValue), label: "w")
        XCTAssertEqual(Hex.encode(wire.prefix(32)), ns)
        XCTAssertEqual(wire[32], 1, "root plane")
        let nonce = wire.subdata(in: (wire.count - 80)..<(wire.count - 72)).withUnsafeBytes { $0.load(as: UInt64.self) }
        XCTAssertGreaterThan(nonce, 1_600_000_000_000, "floored at the clock, in ms")
        let input = Warrants.GovernanceInput(
            scope: ns, op: genesis, authorAccount: cb.account, executor: rep("33"), executorKey: rep("77"),
            nonce: nonce,
            notAfter: wire.subdata(in: (wire.count - 72)..<(wire.count - 64)).withUnsafeBytes {
                $0.load(as: UInt64.self)
            })
        let devicePk = try Ed25519.publicKey(seed: keys.signSecret)
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: devicePk, signature: wire.suffix(64),
                message: try Warrants.governancePreimage(input, devicePublicKey: devicePk)))
    }

    func testFoundNamespaceRefusesABadMaskBeforeSigning() async throws {
        let cb = wallet.approve(keys, state: nil)
        let client = RelayClient(
            relayURL: relay, authorAccount: cb.account, authorProof: cb.credential, keys: keys,
            nonces: MemoryWarrantNonceStore(), session: MockURLProtocol.makeSession())
        do {
            _ = try await client.foundNamespace(
                executor: RelayExecutor(executorAccount: rep("33"), executorKey: rep("77")), defaultCapabilities: 512)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("CAN_AUTHOR_ON_BEHALF"))
        }
        XCTAssertTrue(rig.seen.isEmpty, "nothing was sent")
    }

    private func signedIn() -> (CloudSignIn, CloudSession) {
        let cb = wallet.approve(keys, state: nil)
        let session = CloudSession(
            account: cb.account, device: cb.device, credential: cb.credential, relayUrl: relay,
            executorAccount: rep("33"))
        let signIn = CloudSignIn(
            config: CloudConfig(cloudBaseURL: cloud, relayKeyVerifier: PinnedRelayKeyVerifier(nodeKey: rep("77"))),
            keyStore: .memory(keys), sessionStore: .memory(session), urlSession: MockURLProtocol.makeSession())
        return (signIn, session)
    }

    private func connection(_ session: CloudSession, mero: Bool = false) -> CloudConnection {
        let relayClient = RelayClient(
            relayURL: relay, authorAccount: session.account, authorProof: session.credential, keys: keys,
            nonces: MemoryWarrantNonceStore(), executorAccount: session.executorAccount,
            session: MockURLProtocol.makeSession())
        let client =
            mero
            ? Mero(
                config: MeroConfig(baseURL: URL(string: relay)!, tokenStore: MemoryTokenStore()),
                session: MockURLProtocol.makeSession()) : nil
        return CloudConnection(session: session, relay: relayClient, mero: client, nodeKey: rep("77"), readNote: nil)
    }

    func testCloudFoundNamespaceResolvesTheAppNamesItAndEnablesHa() async throws {
        let (signIn, session) = signedIn()
        // The namespace id is drawn at random: answer every group's governance route.
        let seen = Seen()
        MockURLProtocol.setHandler { req in
            let path = req.url!.path
            seen.add("\(req.httpMethod ?? "") \(path)")
            if path.hasSuffix("/governance-intents") {
                let group = path.split(separator: "/")[2]
                if req.httpMethod == "GET" {
                    return CloudRig.stub(
                        200,
                        #"{"data":{"executorAccount":"\#(String(repeating: "33", count: 32))","executorKey":"\#(String(repeating: "77", count: 32))","groupId":"\#(group)","canActOnBehalf":true}}"#
                    )
                }
                return CloudRig.stub(200, #"{"data":{"groupId":"\#(group)","teeEnabled":true}}"#)
            }
            if path == "/api/v2/bundles" {
                return CloudRig.stub(
                    200, #"[{"package":"com.calimero.curb","signerId":"did:key:z6MkX","appVersion":"0.3.0"}]"#)
            }
            if path.hasSuffix("/enable-ha") { return CloudRig.stub(200, #"{"status":"enabled"}"#) }
            return CloudRig.stub(404, "{}")
        }
        let founded = try await signIn.foundNamespace(
            connection(session), name: "Team", package: "com.calimero.curb", registryURL: "https://registry.test")
        XCTAssertTrue(founded.haEnabled, founded.haError ?? "")
        XCTAssertTrue(founded.teeEnabled)
        XCTAssertEqual(founded.defaultCapabilitiesSet, true)
        XCTAssertEqual(
            founded.namespaceId, try GovernanceOps.foundedNamespaceId(founder: session.account, salt: founded.salt))
        let ns = founded.namespaceId
        XCTAssertEqual(
            seen.all.filter { $0.hasSuffix("governance-intents") },
            // The genesis, then describe + post for the application, the capabilities and the name.
            ["POST /admin-api/groups/\(ns)/governance-intents"]
                + Array(
                    repeating: [
                        "GET /admin-api/groups/\(ns)/governance-intents",
                        "POST /admin-api/groups/\(ns)/governance-intents",
                    ], count: 3
                ).flatMap { $0 })
        XCTAssertTrue(seen.all.contains("POST /api/cloud/accounts/\(session.account)/namespaces/\(ns)/enable-ha"))
    }

    func testCloudInvitationNamesTheRelaysAndCarriesTheRelayWhenUnrouted() async throws {
        let (signIn, session) = signedIn()
        let ns = rep("ab")
        rig.on(
            "GET", "/admin-api/groups/\(ns)/members",
            json:
                #"{"members":[{"identity":"\#(session.account)","role":"Admin"},{"identity":"\#(rep("EE"))","role":"RelayTee"}]}"#
        )
        rig.on(
            "GET", "/admin-api/groups/\(ns)",
            json: """
                {"data":{"groupId":"\(ns)","appKey":"\(rep("12"))","targetApplicationId":"\(rep("34"))","memberCount":2,
                 "contextCount":0,"defaultCapabilities":231,"subgroupVisibility":"open"}}
                """)
        rig.on("GET", "/api/cloud/namespaces/\(ns)/challenge", json: #"{"nonce":"n"}"#)
        rig.on("GET", "/api/cloud/namespaces/\(ns)/admitters", json: #"{"admitters":[]}"#)

        let invitation = try await signIn.createNamespaceInvitation(connection(session, mero: true), namespaceId: ns)
        XCTAssertEqual(invitation.invitation.admitters, [rep("ee")])
        XCTAssertEqual(invitation.admitterAddrs, [relay])
        XCTAssertEqual(invitation.inviterAccount, session.account)
        XCTAssertEqual(invitation.applicationId, Array(repeating: 0x34, count: 32))
        XCTAssertEqual(invitation.appKey, Array(repeating: 0x12, count: 32))
        let devicePk = try Ed25519.publicKey(seed: keys.signSecret)
        XCTAssertEqual(invitation.invitation.inviterIdentity, devicePk.map { Int($0) })
        XCTAssertTrue(
            Ed25519.verify(
                publicKey: devicePk, signature: try Hex.decode(invitation.inviterSignature, label: "s", bytes: 64),
                message: try GroupInvitations.hash(invitation.invitation)))

        // No relay in it and nobody routed: nobody could claim it.
        rig.on(
            "GET", "/admin-api/groups/\(ns)/members",
            json: #"{"members":[{"identity":"\#(session.account)","role":"Admin"}]}"#)
        do {
            _ = try await signIn.createNamespaceInvitation(connection(session, mero: true), namespaceId: ns)
            XCTFail("expected not-claimable")
        } catch AccountError.invitationNotClaimable(_, let reason) {
            XCTAssertEqual(reason, "not-hosted")
        }
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
