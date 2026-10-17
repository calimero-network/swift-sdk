import MeroKit
import XCTest

@testable import MeroKitUI

/// Ports of mero-react `auth/node-trust.test.ts` and `auth/token-adoption.test.ts`.
final class NodeTrustTests: XCTestCase {
    func testSameOrigin() {
        XCTAssertTrue(NodeTrust.sameOrigin("https://node.example.com/a", "https://node.example.com/b"))
        XCTAssertFalse(NodeTrust.sameOrigin("https://node.example.com", "https://evil.com"))
        XCTAssertFalse(NodeTrust.sameOrigin("https://node.example.com:2428", "https://node.example.com:9999"))
        XCTAssertFalse(NodeTrust.sameOrigin("http://node.example.com", "https://node.example.com"))
        XCTAssertFalse(NodeTrust.sameOrigin("not a url", "https://node.example.com"))
        XCTAssertFalse(NodeTrust.sameOrigin("https://node.example.com", ""))
        XCTAssertTrue(NodeTrust.sameOrigin("https://node.example.com:443/x", "https://NODE.example.com"))
    }

    private let initiated = "https://my-node.example.com"

    func testNoCandidateUsesTheInitiatedNode() {
        let result = NodeTrust.resolveTrustedNodeURL(candidate: nil, initiated: initiated)
        XCTAssertEqual(result, NodeTrust.TrustedNode(url: initiated, rejected: false))
    }

    func testACandidateOnTheInitiatedOriginIsAccepted() {
        let result = NodeTrust.resolveTrustedNodeURL(candidate: "https://my-node.example.com/cb", initiated: initiated)
        XCTAssertEqual(result, NodeTrust.TrustedNode(url: "https://my-node.example.com/cb", rejected: false))
    }

    func testAForeignCandidateIsRejected() {
        let result = NodeTrust.resolveTrustedNodeURL(candidate: "https://evil.com", initiated: initiated)
        XCTAssertEqual(result, NodeTrust.TrustedNode(url: nil, rejected: true))
        let port = NodeTrust.resolveTrustedNodeURL(
            candidate: "https://my-node.example.com:9999", initiated: "https://my-node.example.com:2428")
        XCTAssertTrue(port.rejected)
        XCTAssertNil(port.url)
    }

    func testTheAllowlistAnchorsACallbackWithNoInitiatedNode() {
        let allowed = ["https://trusted.example.com"]
        let ok = NodeTrust.resolveTrustedNodeURL(
            candidate: "https://trusted.example.com/cb", initiated: nil, allowedNodeURLs: allowed)
        XCTAssertEqual(ok, NodeTrust.TrustedNode(url: "https://trusted.example.com/cb", rejected: false))
        let evil = NodeTrust.resolveTrustedNodeURL(
            candidate: "https://evil.com", initiated: nil, allowedNodeURLs: allowed)
        XCTAssertEqual(evil, NodeTrust.TrustedNode(url: nil, rejected: true))
    }

    func testNoTrustAnchorRejects() {
        let result = NodeTrust.resolveTrustedNodeURL(candidate: "https://unknown.example.com", initiated: nil)
        XCTAssertEqual(result, NodeTrust.TrustedNode(url: nil, rejected: true))
    }
}

final class TokenAdoptionTests: XCTestCase {
    private let node = "https://node-a.example.com"
    private let otherNode = "https://node-b.example.com"
    private let nowSec = Double(Int(Date().timeIntervalSince1970))

    private func t(_ offset: Double) -> Double { nowSec + offset }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// An unsigned JWT carrying `claims` (only the payload is read).
    private func jwt(_ claims: [String: Any]) -> String {
        func b64(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "HS256", "typ": "JWT"])).\(b64(claims)).sig"
    }

    private func stored(access: String? = nil, refresh: String = "stored-refresh") -> TokenData {
        TokenData(
            accessToken: access ?? jwt(["iat": t(-60), "exp": t(3540)]), refreshToken: refresh,
            expiresAt: date(t(3540)))
    }

    private func adopt(
        _ access: String, _ refresh: String, node callbackNode: String? = nil, stored: TokenData?,
        storedNode: String? = nil
    ) -> TokenAdoption.Decision {
        TokenAdoption.resolve(
            callbackAccessToken: access, callbackRefreshToken: refresh, callbackNodeURL: callbackNode ?? node,
            stored: stored, storedNodeURL: storedNode)
    }

    func testDecodeClaims() {
        typealias Claims = TokenAdoption.Claims
        XCTAssertEqual(TokenAdoption.decodeClaims(jwt(["iat": 1000, "exp": 2000])), Claims(iat: 1000, exp: 2000))
        XCTAssertNil(TokenAdoption.decodeClaims("opaque-token"))
        XCTAssertNil(TokenAdoption.decodeClaims("a.b.c"))
        XCTAssertNil(TokenAdoption.decodeClaims(""))
        XCTAssertEqual(TokenAdoption.decodeClaims(jwt(["iat": 0, "exp": -1])), Claims(iat: nil, exp: nil))
        XCTAssertEqual(TokenAdoption.decodeClaims(jwt(["sub": "no-timestamps"])), Claims(iat: nil, exp: nil))
    }

    func testAFreshLoginSeedsFromTheCallback() {
        let access = jwt(["iat": t(0), "exp": t(3600)])
        let decision = adopt(access, "r1", stored: nil)
        let expected = TokenData(accessToken: access, refreshToken: "r1", expiresAt: date(t(3600)))
        XCTAssertEqual(decision, .adopt(expected, .freshLogin))
    }

    func testAStaleCallbackNeverOverwritesARotatedBundle() {
        let stale = jwt(["iat": t(-600), "exp": t(3000)])
        let decision = adopt(stale, "consumed-refresh", stored: stored(refresh: "rotated-refresh"), storedNode: node)
        XCTAssertEqual(decision, .ignore)
        XCTAssertEqual(decision.reason, .stale)
    }

    func testAReplayOfTheStoredAccessTokenIsStale() {
        let held = stored(refresh: "rotated-refresh")
        XCTAssertEqual(adopt(held.accessToken, "original-refresh", stored: held, storedNode: node), .ignore)
    }

    func testANewerCallbackIsAdopted() {
        let fresh = jwt(["iat": t(60), "exp": t(3660)])
        let decision = adopt(fresh, "r2", stored: stored(), storedNode: node)
        let expected = TokenData(accessToken: fresh, refreshToken: "r2", expiresAt: date(t(3660)))
        XCTAssertEqual(decision, .adopt(expected, .newer))
    }

    func testANodeChangeReseedsWithoutTheOldRefreshToken() {
        let access = jwt(["iat": t(-600), "exp": t(3000)])
        let decision = adopt(
            access, "node-b-refresh", node: otherNode, stored: stored(refresh: "node-a-refresh"), storedNode: node)
        let expected = TokenData(accessToken: access, refreshToken: "node-b-refresh", expiresAt: date(t(3000)))
        XCTAssertEqual(decision, .adopt(expected, .nodeChanged))
    }

    func testASamePathlessOriginIsTheSameNode() {
        let stale = jwt(["iat": t(-600), "exp": t(3000)])
        let decision = adopt(
            stale, "consumed-refresh", node: "\(node)/auth/callback", stored: stored(), storedNode: node)
        XCTAssertEqual(decision, .ignore)
    }

    func testAnAccessOnlyCallbackKeepsTheStoredRefreshToken() {
        let fresh = jwt(["iat": t(60), "exp": t(3660)])
        let decision = adopt(fresh, "", stored: stored(refresh: "rotated-refresh"), storedNode: node)
        let expected = TokenData(accessToken: fresh, refreshToken: "rotated-refresh", expiresAt: date(t(3660)))
        XCTAssertEqual(decision, .adopt(expected, .newer))
        let seeded = jwt(["iat": t(0), "exp": t(3600)])
        let freshLogin = adopt(seeded, "", stored: nil)
        XCTAssertEqual(freshLogin.tokens?.refreshToken, "")
        XCTAssertEqual(freshLogin.reason, .freshLogin)
    }

    func testAMissingRefreshTokenIsFilledWithoutDowngradingTheAccessToken() {
        let held = stored(refresh: "")
        let decision = adopt(jwt(["iat": t(-600), "exp": t(3000)]), "r1", stored: held, storedNode: node)
        var filled = held
        filled.refreshToken = "r1"
        XCTAssertEqual(decision, .adopt(filled, .fillRefresh))
    }

    func testAnOpaqueStoredTokenComparesOnItsRecordedExpiry() {
        let held = TokenData(accessToken: "opaque", refreshToken: "rotated-refresh", expiresAt: date(t(3540)))
        XCTAssertEqual(adopt(jwt(["exp": t(3000)]), "consumed-refresh", stored: held, storedNode: node), .ignore)
        let fresh = jwt(["exp": t(7200)])
        let expected = TokenData(accessToken: fresh, refreshToken: "rotated-refresh", expiresAt: date(t(7200)))
        XCTAssertEqual(adopt(fresh, "", stored: held, storedNode: node), .adopt(expected, .newer))
    }

    func testAnUndecodableCallbackTokenIsRefused() {
        XCTAssertEqual(adopt("opaque-callback-token", "consumed-refresh", stored: stored(), storedNode: node), .ignore)
    }
}
