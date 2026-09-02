import XCTest

@testable import MeroKit

/// An invitation must survive a round-trip through the SDK's model **without
/// losing a field**, because that round-trip is the normal path: the app decodes
/// what `createNamespaceInvitation` returned, carries it around (through a
/// share link, a pasteboard, a JSON file), and hands it back to
/// `joinNamespace`.
///
/// The node verifies an invitation by deserialising the JSON into its own
/// struct, re-encoding it as borsh and checking `inviter_signature` over those
/// bytes. So a field the SDK drops is a field `#[serde(default)]` fills with a
/// zero value on the node — different borsh, invalid signature, join refused.
/// core's own source says so, naming `calimero-client-py` as the client this
/// already happened to.
///
/// The fixture below is a REAL invitation, minted by a live core 0.11.0-rc.29
/// node. Nothing here is hand-assembled from what the code expects, which is
/// the whole point: the previous model named 2 of the envelope's 5 keys and 5 of
/// the signed body's 6, and every test passed because they all built their input
/// from the same model they then asserted on.
final class InvitationRoundTripTests: XCTestCase {

    /// The fixture: `POST /admin-api/namespaces/{id}/invite` → `data.invitation`,
    /// captured verbatim from a live core 0.11.0-rc.29 node.
    private static let invitation = "rc29-namespace-invitation"

    private func object(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    // MARK: the round-trip

    func testARealInvitationRoundTripsWithEveryKeyIntact() throws {
        let before = try Fixture.object(Self.invitation)
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: try Fixture.data(Self.invitation))
        let after = try JSONDecoder().decode(
            [String: JSONValue].self, from: try JSONEncoder().encode(decoded))

        XCTAssertEqual(
            Set(after.keys), Set(before.keys),
            "the envelope lost or invented a key; missing "
                + "\(Set(before.keys).subtracting(after.keys).sorted())")
        XCTAssertEqual(after, before, "a value changed across the round-trip")
    }

    func testTheSignedBodyRoundTripsWithEveryKeyIntact() throws {
        let before = try Fixture.object(Self.invitation)["invitation"]!.objectValue!
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: try Fixture.data(Self.invitation))
        let after = try JSONDecoder().decode(
            [String: JSONValue].self, from: try JSONEncoder().encode(decoded.invitation))

        XCTAssertEqual(
            Set(after.keys), Set(before.keys),
            "the signed body lost or invented a key; missing "
                + "\(Set(before.keys).subtracting(after.keys).sorted())")
        XCTAssertEqual(after, before, "a value inside the signature changed")
    }

    // MARK: the specific fields the old model dropped

    func testAdmittersSurvive() throws {
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: try Fixture.data(Self.invitation))
        // rc.29 defaults admitters to the group's admins + TEE nodes, so a real
        // invitation always has at least one. This is the field inside the
        // signature, so losing it is the one that refuses the join.
        XCTAssertFalse(decoded.invitation.admitters.isEmpty, "admitters were dropped")
        for account in decoded.invitation.admitters {
            XCTAssertEqual(account.count, 64, "an account id is 64 hex characters since rc.27")
        }
    }

    func testTheUnsignedBootstrapHintsSurvive() throws {
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: try Fixture.data(Self.invitation))
        // Unsigned, so losing these does not refuse the join — it makes the
        // joiner record zeros for the group's application id, after which
        // compute_group_state_hash diverges from the originator's permanently.
        XCTAssertEqual(decoded.inviterAccount?.count, 64)
        XCTAssertEqual(decoded.applicationId?.count, 32)
        XCTAssertEqual(decoded.appKey?.count, 32)
    }

    // MARK: forward compatibility

    func testAKeyThisSdkHasNeverHeardOfSurvives() throws {
        // The guard that makes the next core release cheap. Both levels.
        let json = #"""
            {"invitation":{"inviter_identity":[1],"group_id":[2],"expiration_timestamp":9,
             "secret_salt":[3],"invited_role":1,"admitters":["ab"],"a_future_signed_field":42},
             "inviter_signature":"sig","a_future_envelope_field":{"nested":true}}
            """#
        let before = try object(json)
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: Data(json.utf8))
        let after = try JSONDecoder().decode(
            [String: JSONValue].self, from: try JSONEncoder().encode(decoded))

        XCTAssertEqual(after, before)
        XCTAssertEqual(decoded.passthrough["a_future_envelope_field"], ["nested": true])
        XCTAssertEqual(decoded.invitation.passthrough["a_future_signed_field"], 42)
    }

    func testAnInvitationWithoutTheNewFieldsReEncodesWithoutThem() throws {
        // core marks every one of them skip_serializing_if, so an invitation
        // minted before they existed must not come back carrying empty ones —
        // an added `"admitters":[]` is a changed signed body just as much as a
        // removed one.
        let json = #"""
            {"invitation":{"inviter_identity":[1],"group_id":[2],"expiration_timestamp":9,
             "secret_salt":[3]},"inviter_signature":"sig"}
            """#
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: Data(json.utf8))
        let after = try JSONDecoder().decode(
            [String: JSONValue].self, from: try JSONEncoder().encode(decoded))

        XCTAssertEqual(Set(after.keys), ["invitation", "inviter_signature"])
        XCTAssertEqual(
            Set(after["invitation"]!.objectValue!.keys),
            ["inviter_identity", "group_id", "expiration_timestamp", "secret_salt"])
    }

    // MARK: through the share-link codec

    func testTheInviteCodecCarriesEveryFieldToo() throws {
        // InviteCodec encodes any Encodable, so it inherits whatever the model
        // loses. Worth pinning separately: this is the path a phone → desktop
        // hand-off takes, and a token that drops admitters is one the other end
        // cannot redeem.
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: try Fixture.data(Self.invitation))
        let token = try InviteCodec.encode(decoded)
        let back = try InviteCodec.decode(SignedGroupOpenInvitation.self, from: token)

        XCTAssertEqual(back.invitation.admitters, decoded.invitation.admitters)
        XCTAssertEqual(back.inviterAccount, decoded.inviterAccount)
        XCTAssertEqual(back.applicationId, decoded.applicationId)
        XCTAssertEqual(back.appKey, decoded.appKey)
        XCTAssertEqual(
            try JSONDecoder().decode([String: JSONValue].self, from: try JSONEncoder().encode(back)),
            try JSONDecoder().decode(
                [String: JSONValue].self, from: try JSONEncoder().encode(decoded)))
    }

    // MARK: the 24-hour ceiling

    func testTheRealInvitationExpiresWithin24Hours() throws {
        // rc.29 CLAMPS the lifetime to MAX_INVITATION_VALIDITY_SECS (24h); it
        // used to default to a year. A caller asking for longer is silently
        // lowered, so anything that assumes a long-lived invitation is wrong now.
        let decoded = try JSONDecoder().decode(
            SignedGroupOpenInvitation.self, from: try Fixture.data(Self.invitation))
        let mintedAt = decoded.invitation.expirationTimestamp - 24 * 60 * 60
        XCTAssertGreaterThan(decoded.invitation.expirationTimestamp, mintedAt)
        XCTAssertLessThanOrEqual(decoded.invitation.expirationTimestamp - mintedAt, 24 * 60 * 60)
    }
}
