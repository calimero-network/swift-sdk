import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` that routes every request through a registered handler, so
/// tests can stub HTTP without a live node. (Swift's clean way to fake `URLSession`.)
final class MockURLProtocol: URLProtocol {
    /// Handler: given a request, return status, headers, and body bytes.
    struct Stub: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    /// Thread-safe registry, keyed by nothing — a single handler serves all requests.
    private static let lock = NSLock()
    private static var _handler: (@Sendable (URLRequest) -> Stub)?

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
    }

    private static func handler() -> (@Sendable (URLRequest) -> Stub)? {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }

    /// Build a `URLSession` wired to this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

    override func stopLoading() {}
}

/// A mutable, thread-safe counter for tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
