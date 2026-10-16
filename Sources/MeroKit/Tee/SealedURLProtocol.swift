import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `URLProtocol` behind ``SealedTransport/urlSession(configuration:)``:
/// every request a session built on it makes is sealed by the
/// ``SealedTransport`` registered for its URL, and a request no transport
/// covers fails instead of going out in the clear. (mero-js passes its sealed
/// `fetch` wherever a `fetch` goes; this is the `URLSession` equivalent.)
///
/// Transports are registered by base URL, one per base URL: registering a
/// second for the same base URL replaces the first.
public final class SealedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var transports: [String: SealedTransport] = [:]

    private var loadTask: Task<Void, Never>?

    /// Route requests under `transport`'s base URL through it.
    public static func register(_ transport: SealedTransport) {
        lock.lock()
        defer { lock.unlock() }
        transports[transport.nodeURL] = transport
    }

    /// Stop routing requests under `baseURL` (a session that still uses it then fails closed).
    public static func unregister(baseURL: URL) {
        guard let parts = SealedURLParts(baseURL) else { return }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        lock.lock()
        defer { lock.unlock() }
        transports[parts.origin + path] = nil
    }

    /// Forget every registered transport.
    public static func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        transports.removeAll()
    }

    /// The transport whose base URL covers `url`, the most specific first.
    static func transport(for url: URL) -> SealedTransport? {
        lock.lock()
        let all = Array(transports.values)
        lock.unlock()
        return all.filter { $0.covers(url) }.max { $0.basePath.count < $1.basePath.count }
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        let scheme = request.url?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        let request = self.request
        let client = SealedProtocolClient(self)
        loadTask = Task {
            do {
                guard let url = request.url, let transport = SealedURLProtocol.transport(for: url) else {
                    let named = request.url?.absoluteString ?? "a request with no URL"
                    throw TeeTrustError("Refusing to send \(named): no sealed transport covers it")
                }
                let response = try await transport.send(request)
                guard
                    let http = HTTPURLResponse(
                        url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
                else { throw TeeTrustError("The sealed response could not be read") }
                client.received(http)
                for try await chunk in response.body { client.loaded(chunk) }
                client.finished()
            } catch {
                client.failed(error)
            }
        }
    }

    public override func stopLoading() {
        loadTask?.cancel()
    }
}

/// The protocol's client, handed to the task that feeds it.
private struct SealedProtocolClient: @unchecked Sendable {
    let owner: URLProtocol

    init(_ owner: URLProtocol) { self.owner = owner }

    func received(_ response: HTTPURLResponse) {
        owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func loaded(_ data: Data) {
        owner.client?.urlProtocol(owner, didLoad: data)
    }

    func finished() {
        owner.client?.urlProtocolDidFinishLoading(owner)
    }

    func failed(_ error: Error) {
        owner.client?.urlProtocol(owner, didFailWithError: error)
    }
}

// MARK: - Attesting the transport key

/// What `POST /admin-api/tee/attest {bindTransportKey: true}` answered, as
/// far as sealing reads it.
public struct TransportAttestation: Sendable, Equatable {
    public var quoteB64: String
    public var transportPublicKey: String?
    public var collateral: DcapCollateral?

    public init(quoteB64: String, transportPublicKey: String? = nil, collateral: DcapCollateral? = nil) {
        self.quoteB64 = quoteB64
        self.transportPublicKey = transportPublicKey
        self.collateral = collateral
    }

    /// From the attest endpoint's `data` (or the whole body).
    public init(json: JSONValue) throws {
        let data = json["data"] ?? json
        guard let quote = data["quoteB64"]?.stringValue else {
            throw TeeTrustError("The attestation response is malformed")
        }
        self.quoteB64 = quote
        self.transportPublicKey = data["transportPublicKey"]?.stringValue
        if let collateral = data["collateral"], collateral != .null {
            self.collateral = try DcapCollateral(json: collateral)
        } else {
            self.collateral = nil
        }
    }
}

/// Ask a node for its transport key and accept it only if a quote `verifier`
/// accepted commits to it. (== mero-js `fetchAttestedTransportKey`.)
///
/// `applicationHash` (hex), when given with `applicationId`, is the bytecode
/// hash you expect the attested application to have: the node is asked to
/// bind that application, and the quote only verifies if it runs that exact
/// bytecode.
public func fetchAttestedTransportKey(
    _ teeAttest: @Sendable (TeeAttestRequest) async throws -> TransportAttestation,
    verifier: any TransportQuoteVerifier, applicationId: String? = nil, applicationHash: String? = nil
) async throws -> Data {
    guard (applicationId == nil) == (applicationHash == nil) else {
        throw TeeTrustError("applicationId and applicationHash are given together or not at all")
    }
    let nonce = Hex.encode(randomBytes(32))
    let attested = try await teeAttest(
        TeeAttestRequest(
            nonce: nonce, applicationId: applicationId, bindTransportKey: true,
            includeCollateral: verifier.includeCollateral))
    guard let reported = attested.transportPublicKey else {
        throw TeeTrustError("The node did not report a transport key; it predates sealed transport")
    }
    let transportKey = try Hex.decode(reported, label: "transportPublicKey", bytes: 32)
    let inner = try applicationHash.map { try Hex.decode($0, label: "applicationHash", bytes: 32) } ?? Data(count: 32)
    let suffix = Hex.encode(transportKeyBinding(inner, transportKey))
    let verified = try await verifier.verify(
        TransportQuoteArgs(
            quoteB64: attested.quoteB64, nonce: nonce, reportDataSuffix: suffix, collateral: attested.collateral))
    guard verified else {
        throw TeeTrustError("The attestation did not verify, so its transport key is not trusted")
    }
    return transportKey
}

/// ``fetchAttestedTransportKey(_:verifier:applicationId:applicationHash:)`` through a node's ``AdminApi``.
public func fetchAttestedTransportKey(
    _ admin: AdminApi, verifier: any TransportQuoteVerifier, applicationId: String? = nil,
    applicationHash: String? = nil
) async throws -> Data {
    try await fetchAttestedTransportKey(
        { request in
            let data = try await admin.teeAttest(request)
            return TransportAttestation(
                quoteB64: data.quoteB64, transportPublicKey: data.transportPublicKey,
                collateral: try data.collateral.map { try DcapCollateral(json: $0) })
        }, verifier: verifier, applicationId: applicationId, applicationHash: applicationHash)
}

extension SealedTransport {
    /// A sealed transport for a node known only by URL: it attests the
    /// node's transport key with `verifier`, over `POST /admin-api/tee/attest`
    /// (the one call that needs no credential and is never sealed), and seals
    /// everything else to it. A restarted node is attested again, through the
    /// same verifier. (== mero-js `createAttestedSealedFetch`.)
    ///
    /// This is what to give a ``RelayClient`` for a TEE relay (its
    /// ``urlSession(configuration:)``), so the warrant and the method's
    /// arguments reach only the attested TD.
    public static func attested(
        baseURL: URL, verifier: any TransportQuoteVerifier, applicationId: String? = nil,
        applicationHash: String? = nil, session: URLSession = .shared
    ) throws -> SealedTransport {
        try attested(
            baseURL: baseURL, verifier: verifier, applicationId: applicationId, applicationHash: applicationHash,
            session: session, unguardedFallback: false)
    }

    static func attested(
        baseURL: URL, verifier: any TransportQuoteVerifier, applicationId: String?, applicationHash: String?,
        session: URLSession, unguardedFallback: Bool
    ) throws -> SealedTransport {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let attestURL = URL(string: base + "/admin-api/tee/attest") else {
            throw TeeTrustError("bad node URL \(baseURL.absoluteString)")
        }
        let teeAttest: @Sendable (TeeAttestRequest) async throws -> TransportAttestation = { request in
            var post = URLRequest(url: attestURL)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.httpBody = try MeroJSON.encode(request)
            let (data, response) = try await session.data(for: post)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw TeeTrustError("The node refused to attest: HTTP \(status)")
            }
            guard let json = try? MeroJSON.decode(JSONValue.self, from: data), json["data"] != nil else {
                throw TeeTrustError("The attestation response is malformed")
            }
            return try TransportAttestation(json: json)
        }
        let attest: @Sendable () async throws -> Data = {
            try await fetchAttestedTransportKey(
                teeAttest, verifier: verifier, applicationId: applicationId, applicationHash: applicationHash)
        }
        return try SealedTransport(
            baseURL: baseURL, key: .attest(attest), session: session, unguardedFallback: unguardedFallback)
    }
}
