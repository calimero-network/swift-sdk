import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` that routes every request through a registered handler, so
/// tests can stub HTTP without a live node — Swift's clean way to fake `URLSession`
/// (and the route-mocking analog of Playwright's `page.route`).
public final class MockURLProtocol: URLProtocol {
    /// Handler result: status, headers, and body bytes for a request.
    public struct Stub: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data

        public init(status: Int, headers: [String: String], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Stub)?

    /// Register the single handler that serves all requests.
    public static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
    }

    private static func handler() -> (@Sendable (URLRequest) -> Stub)? {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }

    /// Build a `URLSession` wired to this protocol.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let handler = MockURLProtocol.handler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}
}

/// A mutable, thread-safe counter for tests.
public final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    @discardableResult
    public func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
