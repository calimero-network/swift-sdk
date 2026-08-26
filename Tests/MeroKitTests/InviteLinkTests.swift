import XCTest

@testable import MeroKit

final class InviteLinkTests: XCTestCase {

    func testBuildsTheCanonicalShareableLink() {
        let link = InviteLink.invitation(token: "TOKEN", slug: "com.calimero.mero-ar")
        XCTAssertEqual(
            link,
            "https://links.calimero.network/com.calimero.mero-ar/join?invitation=TOKEN")
    }

    func testPercentEncodesTheToken() {
        let link = InviteLink.invitation(token: "a b+c", slug: "com.calimero.mero-tag")
        XCTAssertTrue(link.contains("invitation=a%20b+c") || link.contains("invitation=a%20b%2Bc"))
        XCTAssertFalse(link.contains("a b"))
    }

    func testReadsTheTokenBackOutOfItsOwnLink() {
        let link = InviteLink.invitation(token: "ROUNDTRIP", slug: "com.calimero.mero-ar")
        XCTAssertEqual(InviteLink.token(fromPasted: link), "ROUNDTRIP")
    }

    func testReadsATokenFromACalimeroSchemeLink() {
        // The dotted slug is why this is split by hand: URL host parsing on a
        // non-special scheme mangles `com.calimero.mero-ar`.
        let pasted = "calimero://com.calimero.mero-ar/join?invitation=DEEPLINK"
        XCTAssertEqual(InviteLink.token(fromPasted: pasted), "DEEPLINK")
    }

    func testAcceptsABareToken() {
        XCTAssertEqual(InviteLink.token(fromPasted: "  JUSTATOKEN  "), "JUSTATOKEN")
    }

    func testDecodesPercentEncodingOnTheWayBack() {
        let pasted = "https://links.calimero.network/com.calimero.mero-ar/join?invitation=a%20b"
        XCTAssertEqual(InviteLink.token(fromPasted: pasted), "a b")
    }

    func testSurvivesExtraQueryParameters() {
        let pasted =
            "https://links.calimero.network/com.calimero.mero-ar/join?ref=x&invitation=TOK&y=2"
        XCTAssertEqual(InviteLink.token(fromPasted: pasted), "TOK")
    }

    func testReturnsNilOnlyForEmptyInput() {
        XCTAssertNil(InviteLink.token(fromPasted: "   "))
        XCTAssertNotNil(InviteLink.token(fromPasted: "anything else"))
    }

    func testALinkWithNoInvitationParameterComesBackUnchanged() {
        let pasted = "https://links.calimero.network/com.calimero.mero-ar/join?other=1"
        XCTAssertEqual(InviteLink.token(fromPasted: pasted), pasted)
    }
}
