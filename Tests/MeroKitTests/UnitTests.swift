import XCTest

@testable import MeroKit

final class JWTAndConfigTests: XCTestCase {
    /// Build a minimal unsigned JWT with the given payload claims.
    private func makeJWT(_ claims: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"]))
        let payload = b64url(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).sig"
    }

    func testExpiresAtFromJWTReadsExpClaim() {
        let exp = 2_000_000_000.0  // 2033
        let token = makeJWT(["exp": exp])
        let fallback = Date(timeIntervalSince1970: 0)
        let result = expiresAtFromJWT(token, fallback: fallback)
        XCTAssertEqual(result.timeIntervalSince1970, exp, accuracy: 1)
    }

    func testExpiresAtFromJWTFallsBackOnGarbage() {
        let fallback = Date(timeIntervalSince1970: 12345)
        XCTAssertEqual(expiresAtFromJWT("not-a-jwt", fallback: fallback), fallback)
        XCTAssertEqual(expiresAtFromJWT("a.b.c", fallback: fallback), fallback)
    }

    func testTokenDataRoundTripsEpochMillis() throws {
        let bundle = TokenData(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try MeroJSON.encode(bundle)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["access_token"] as? String, "a")
        XCTAssertEqual(json["refresh_token"] as? String, "r")
        XCTAssertEqual(json["expires_at"] as? Double, 1_700_000_000_000)  // millis

        let decoded = try MeroJSON.decode(TokenData.self, from: data)
        XCTAssertEqual(decoded, bundle)
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let value: JSONValue = [
            "s": "hello",
            "n": 42,
            "f": 3.5,
            "b": true,
            "nil": nil,
            "arr": [1, 2, 3],
            "obj": ["k": "v"],
        ]
        let data = try MeroJSON.encode(value)
        let decoded = try MeroJSON.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testTypedAccessors() {
        let obj: JSONValue = ["name": "mero", "count": 7, "on": true]
        XCTAssertEqual(obj["name"]?.stringValue, "mero")
        XCTAssertEqual(obj["count"]?.intValue, 7)
        XCTAssertEqual(obj["on"]?.boolValue, true)
        XCTAssertNil(obj["missing"])
    }
}

final class SsoLoginTests: XCTestCase {
    func testParseAuthCallbackExtractsAllFields() {
        let url =
            "myapp://auth-callback#access_token=AAA&refresh_token=RRR&application_id=app1&context_id=ctx1&context_identity=id1&node_url=https%3A%2F%2Fnode.example"
        let result = SsoLogin.parseAuthCallback(url)
        XCTAssertEqual(result?.accessToken, "AAA")
        XCTAssertEqual(result?.refreshToken, "RRR")
        XCTAssertEqual(result?.applicationId, "app1")
        XCTAssertEqual(result?.contextId, "ctx1")
        XCTAssertEqual(result?.contextIdentity, "id1")
        XCTAssertEqual(result?.nodeUrl, "https://node.example")
    }

    func testParseAuthCallbackReturnsNilWithoutAccessToken() {
        XCTAssertNil(SsoLogin.parseAuthCallback("myapp://cb#refresh_token=RRR"))
        XCTAssertNil(SsoLogin.parseAuthCallback("myapp://cb-no-hash"))
    }

    func testBuildAuthLoginUrl() {
        let url = SsoLogin.buildAuthLoginUrl(
            nodeUrl: "https://node.example/",
            options: AuthLoginOptions(
                callbackUrl: "myapp://cb",
                mode: "login",
                packageName: "com.acme.app",
                permissions: ["admin", "context"],
                registryUrl: "https://registry.example",
                packageVersion: "1.2.3"
            )
        )
        XCTAssertTrue(url.hasPrefix("https://node.example/auth/login?"))
        XCTAssertTrue(url.contains("callback-url=myapp://cb") || url.contains("callback-url=myapp%3A%2F%2Fcb"))
        XCTAssertTrue(url.contains("mode=login"))
        XCTAssertTrue(url.contains("permissions=admin,context") || url.contains("permissions=admin%2Ccontext"))
        XCTAssertTrue(url.contains("package-name=com.acme.app"))
        XCTAssertTrue(url.contains("package-version=1.2.3"))
        XCTAssertTrue(url.contains("registry-url="))
    }
}

final class CapabilitiesTests: XCTestCase {
    func testHasWithWithout() {
        var mask: UInt32 = 0
        mask = Capabilities.withCap(mask, Capabilities.canInviteMembers)
        mask = Capabilities.withCap(mask, Capabilities.manageMembers)
        XCTAssertTrue(Capabilities.hasCap(mask, Capabilities.canInviteMembers))
        XCTAssertTrue(Capabilities.hasCap(mask, Capabilities.manageMembers))
        XCTAssertFalse(Capabilities.hasCap(mask, Capabilities.canCreateContext))

        mask = Capabilities.withoutCap(mask, Capabilities.manageMembers)
        XCTAssertFalse(Capabilities.hasCap(mask, Capabilities.manageMembers))
        XCTAssertTrue(Capabilities.hasCap(mask, Capabilities.canInviteMembers))
    }
}

final class TokenStoreTests: XCTestCase {
    func testMemoryStoreRoundTrip() {
        let store = MemoryTokenStore()
        XCTAssertNil(store.getTokens())
        let bundle = TokenData(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 100))
        store.setTokens(bundle)
        XCTAssertEqual(store.getTokens(), bundle)
        store.clear()
        XCTAssertNil(store.getTokens())
    }
}

final class RetryTests: XCTestCase {
    func testIsRetryable() {
        XCTAssertTrue(isRetryable(MeroError.network("x")))
        XCTAssertTrue(isRetryable(MeroError.http(HTTPError(status: 500, statusText: "e", url: "u", headers: [:]))))
        XCTAssertTrue(isRetryable(MeroError.http(HTTPError(status: 429, statusText: "e", url: "u", headers: [:]))))
        XCTAssertFalse(isRetryable(MeroError.http(HTTPError(status: 404, statusText: "e", url: "u", headers: [:]))))
        XCTAssertFalse(
            isRetryable(
                MeroError.authRevoked(
                    reason: "token_reuse", http: HTTPError(status: 401, statusText: "e", url: "u", headers: [:]))))
    }

    func testBackoffGrows() {
        XCTAssertEqual(backoffDelay(attempt: 1, jitter: 0), 0.25, accuracy: 0.001)
        XCTAssertEqual(backoffDelay(attempt: 2, jitter: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(backoffDelay(attempt: 3, jitter: 0), 1.0, accuracy: 0.001)
    }
}
