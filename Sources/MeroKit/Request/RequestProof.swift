import Foundation

// Signing one request with the device key, so a keyholder needs no session.
//
// Port of mero-js `src/request-proof/{request-proof,authorizer}.ts`. The
// device key signs the request itself and the certificate its account signed
// says whose key that is; the node verifies both with no store read
// (`crates/server/src/proof_auth.rs`), which is what lets a hosted relay serve
// a caller it has never seen. The node honours it only with
// `--delegated-access`; one without answers `403`, distinct from the `401` a
// bad proof gets.

/// The header a signed request carries. (== mero-js `REQUEST_PROOF_HEADER`.)
public let requestProofHeader = "X-Calimero-Proof"

/// Seconds a request-proof signature stays valid by default.
let defaultRequestProofValidity: UInt64 = 300

/// What ``signRequestProof(_:)`` signs.
public struct RequestProofInput: Sendable {
    /// The HTTP method, exactly as it will be sent. Not folded.
    public var method: String
    /// The path and query, exactly as on the request line.
    public var path: String
    /// The body, exactly as it will be sent; empty for none.
    public var body: Data
    /// The `AccountProof<DeviceCert>`, hex.
    public var credential: String
    /// The certified device's Ed25519 secret, hex. Or pass ``signer``.
    public var deviceSecret: String?
    public var signer: (any Signer)?
    /// Seconds the signature stays valid. Default 300, which is also the most
    /// a node accepts (``maxRequestProofTTLSeconds``); more is refused.
    public var validForSeconds: UInt64?
    /// Override the clock, for tests. Unix seconds.
    public var now: UInt64?

    public init(
        method: String, path: String, body: Data = Data(), credential: String, deviceSecret: String? = nil,
        signer: (any Signer)? = nil, validForSeconds: UInt64? = nil, now: UInt64? = nil
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.credential = credential
        self.deviceSecret = deviceSecret
        self.signer = signer
        self.validForSeconds = validForSeconds
        self.now = now
    }
}

/// Sign one request with the device key and return the `X-Calimero-Proof`
/// value, hex: the two-link `CallerProof`.
///
/// ```
/// CallerProof = <credential bytes> ‖ 0x00 (no session) ‖ RequestSig
/// RequestSig  = u32le(len method) ‖ method ‖ u32le(len path) ‖ path (with query)
///             ‖ body_hash[32] ‖ u64le(issued_at) ‖ u64le(expires_at) ‖ signature[64]
/// ```
///
/// The credential is the account-proof prefix as it is: its length varies
/// with the handoff chain, and a wrong one fails as a refused proof.
public func signRequestProof(_ input: RequestProofInput) async throws -> String {
    guard !input.method.isEmpty else {
        throw AccountError.invalidInput("signRequestProof needs the method the request will use")
    }
    guard input.path.hasPrefix("/") else {
        throw AccountError.invalidInput("signRequestProof needs a path, got \"\(input.path)\"")
    }
    guard input.deviceSecret != nil || input.signer != nil else {
        throw AccountError.invalidInput("signRequestProof needs either `deviceSecret` or `signer`")
    }
    let validFor = try checkedRequestProofTTL(
        input.validForSeconds ?? defaultRequestProofValidity, label: "validForSeconds")
    let issuedAt = input.now ?? unixSeconds()
    let request = try await signRequest(
        RequestSigInput(
            method: input.method, path: input.path, body: input.body, issuedAt: issuedAt,
            expiresAt: issuedAt + validFor,
            signerSecret: input.signer == nil ? input.deviceSecret : nil, signer: input.signer))
    return try callerProof(CallerProofInput(credential: input.credential, request: request))
}

/// What a keyholder holds: a certificate, and the key it certifies.
public struct ProofCredential: Sendable {
    /// The `AccountProof<DeviceCert>`, hex.
    public var credential: String
    /// The certified device's Ed25519 secret, hex. Or pass ``signer``.
    public var deviceSecret: String?
    public var signer: (any Signer)?
    /// Seconds each signature stays valid. Default 300, which is also the most
    /// a node accepts (``maxRequestProofTTLSeconds``); more is refused.
    public var validForSeconds: UInt64?

    public init(
        credential: String, deviceSecret: String? = nil, signer: (any Signer)? = nil, validForSeconds: UInt64? = nil
    ) {
        self.credential = credential
        self.deviceSecret = deviceSecret
        self.signer = signer
        self.validForSeconds = validForSeconds
    }

    /// The device's own keys and certificate.
    public init(credential: String, keys: DeviceKeys, validForSeconds: UInt64? = nil) {
        self.init(credential: credential, deviceSecret: keys.deviceSecret, validForSeconds: validForSeconds)
    }
}

/// One request, as the proof has to see it. (== mero-js `RequestToAuthorize`.)
public typealias RequestToAuthorize = ProofRequest

/// A per-request authorizer: returns the headers to merge into the request.
///
/// Returning headers rather than setting them keeps the transport in charge:
/// core answers a request carrying a token by that token, and consults the
/// proof only when there is none.
public typealias RequestAuthorizer = @Sendable (RequestToAuthorize) async throws -> [String: String]

/// Turn a device certificate into a ``RequestAuthorizer`` for the HTTP
/// client (``MeroConfig/requestProof``) and SSE
/// (``SseConnection/init(baseURL:authorize:session:backoff:)``).
///
/// The credential is validated here, once, rather than on the first request,
/// where a malformed one would surface as a `401` from whichever read ran first.
public func createProofAuthorizer(_ credential: ProofCredential) throws -> RequestAuthorizer {
    guard !credential.credential.isEmpty else {
        throw AccountError.invalidInput("a proof authorizer needs the `credential` from the device certificate")
    }
    guard credential.deviceSecret != nil || credential.signer != nil else {
        throw AccountError.invalidInput("a proof authorizer needs either `deviceSecret` or `signer`")
    }
    _ = try Hex.decodeUnsized(credential.credential, label: "credential")
    if let validFor = credential.validForSeconds {
        _ = try checkedRequestProofTTL(validFor, label: "validForSeconds")
    }
    let signer = try resolveSigner(
        credential.signer == nil ? credential.deviceSecret : nil, credential.signer, label: "deviceSecret")
    return { request in
        let proof = try await signRequestProof(
            RequestProofInput(
                method: request.method, path: request.path, body: request.body, credential: credential.credential,
                signer: signer, validForSeconds: credential.validForSeconds))
        return [requestProofHeader: proof]
    }
}

/// The path and query a proof signs, read from the URL being fetched: the
/// percent-encoded path (`/` when empty) and `?query` as URLSession puts them
/// on the request line, base-URL prefix and escapes included. A bare `?`
/// with nothing after it is dropped, as the transport drops it from the URL.
public func signedPath(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
        return url.path.isEmpty ? "/" : url.path
    }
    let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    guard let query = components.percentEncodedQuery, !query.isEmpty else { return path }
    return "\(path)?\(query)"
}

/// ``signedPath(_:)`` for a URL string. A relative one resolves against
/// `http://localhost`, as mero-js resolves it outside a page.
public func signedPath(_ url: String) -> String {
    let base = URL(string: "http://localhost")
    guard let parsed = URL(string: url, relativeTo: base) else { return url }
    return signedPath(parsed.absoluteURL)
}

/// Whether `headers` carry a request proof, which must never follow a redirect.
public func carriesProof(_ headers: [String: String]) -> Bool {
    headers.keys.contains { $0.caseInsensitiveCompare(requestProofHeader) == .orderedSame }
}

/// The error for a proof-carrying request answered with a redirect: status 0
/// (a withheld response), its explanation in the body text.
/// (== mero-js `refuseProofRedirect`.)
func proofRedirectError(url: String, headers: [String: String]) -> MeroError {
    .http(
        HTTPError(
            status: 0, statusText: "Redirect Not Followed", url: url, headers: headers,
            bodyText: "the node answered with a redirect; a request carrying \(requestProofHeader) "
                + "is not followed to another location"))
}

/// A task delegate that refuses every redirect, so a request carrying a proof
/// is never re-sent to a location it was not signed for. URLSession then
/// hands back the `3xx` itself, which the caller turns into
/// ``proofRedirectError(url:headers:)``.
final class ProofRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
