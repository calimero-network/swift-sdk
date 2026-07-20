import Foundation

/// An in-app mock backend used only when the app is launched with `-uitest-mock`.
/// Returns canned auth + RPC responses so the XCUITest flow is deterministic and
/// needs no live node (the Playwright-style request-interception pattern).
final class UITestMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body): (Int, [String: Any])

        switch path {
        case "/auth/token", "/auth/refresh":
            (status, body) = (200, ["data": ["access_token": "uitest-access", "refresh_token": "uitest-refresh"]])
        case "/jsonrpc":
            (status, body) = (200, ["jsonrpc": "2.0", "id": 1, "result": ["output": 42]])
        default:
            (status, body) = (200, [:])
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
