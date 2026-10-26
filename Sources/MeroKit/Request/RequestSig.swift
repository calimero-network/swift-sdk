import Foundation

// Sign one HTTP request, so a caller's identity travels with it.
//
// Port of mero-js `src/request/{request-sig,caller-proof,proof-signer}.ts`.
// The bottom link of the chain a delegated client presents:
//
// ```text
// account root ──signs──▶ DeviceCert       cold, once, offline
// device key   ──signs──▶ LoginStatement   once per session, hours (optional)
// session key  ──signs──▶ RequestSig       per call   ◀── this file
// ```
//
// **What it binds.** The method (not folded: `HEAD` is not `GET`), the path
// *and query* exactly as on the request line, and a hash of the body. Replay
// inside the window performs the identical request and is bounded, not
// prevented — keep `expiresAt` short.
//
// The byte contract is core's `calimero_account::RequestSig`
// (`crates/account/src/request.rs`), pinned at
// `crates/account/src/tests/request_wire_fixture.rs`; `RequestProofTests`
// asserts the same vectors. The node reads it from `X-Calimero-Proof`
// (`crates/server/src/proof_auth.rs`).

/// core's `REQUEST_SIGN_DOMAIN`.
let requestSignDomain = "calimero.auth.request.v2"
/// core's `REQUEST_BODY_DOMAIN`: its own domain, so the body commitment is
/// never a truncated disclosure of bytes something signs.
let requestBodyDomain = "calimero.auth.request.body.v1"

/// Commit to a request body. Always call it, a body-less request included:
/// an empty body hashes like any other, and there is no "absent body" encoding.
public func requestBodyHash(_ body: Data = Data()) -> Data {
    domainHash(requestBodyDomain, [body])
}

/// ``requestBodyHash(_:)`` over a string's UTF-8 bytes.
public func requestBodyHash(_ body: String) -> Data {
    requestBodyHash(Data(body.utf8))
}

/// The 32 bytes a request signature covers.
func requestSigningPayload(
    method: String, path: String, bodyHash: Data, issuedAt: UInt64, expiresAt: UInt64
) -> Data {
    domainHash(
        requestSignDomain,
        [
            Data(method.utf8),
            Data(path.utf8),
            bodyHash,
            LittleEndian.u64(issuedAt),
            LittleEndian.u64(expiresAt),
        ])
}

/// The borsh `RequestSig`: method, path, body hash, the two times, the signature.
func requestSigBytes(
    method: String, path: String, bodyHash: Data, issuedAt: UInt64, expiresAt: UInt64, signature: Data
) -> Data {
    var w = BorshWriter()
    w.string(method)
    w.string(path)
    w.raw(bodyHash)
    w.u64(issuedAt)
    w.u64(expiresAt)
    w.raw(signature)
    return w.data
}

/// What a caller is about to send.
public struct RequestSigInput: Sendable {
    /// The HTTP method exactly as it will appear on the wire. Not folded.
    public var method: String
    /// The path and query exactly as on the request line
    /// (`/admin-api/blobs?context_id=…`). ``signedPath(_:)`` reads it from a URL.
    public var path: String
    /// The exact bytes that will be sent; empty for none.
    public var body: Data
    /// Unix seconds at signing.
    public var issuedAt: UInt64
    /// Unix seconds after which the node must refuse it. Keep it short.
    public var expiresAt: UInt64
    /// The Ed25519 secret, hex: the session key on the three-link chain, the
    /// device key on the two-link one. Never sent. Or pass ``signer``.
    public var signerSecret: String?
    /// A ``Signer`` for a key that cannot be exported to hex.
    public var signer: (any Signer)?

    public init(
        method: String, path: String, body: Data = Data(), issuedAt: UInt64, expiresAt: UInt64,
        signerSecret: String? = nil, signer: (any Signer)? = nil
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signerSecret = signerSecret
        self.signer = signer
    }
}

/// Sign one request and return the borsh `RequestSig`, hex — the encoding the
/// signature covers, so no second spelling can disagree with it.
public func signRequest(_ input: RequestSigInput) async throws -> String {
    let signer = try resolveSigner(input.signerSecret, input.signer, label: "signerSecret")
    let bodyHash = requestBodyHash(input.body)
    let payload = requestSigningPayload(
        method: input.method, path: input.path, bodyHash: bodyHash, issuedAt: input.issuedAt,
        expiresAt: input.expiresAt)
    let signature = try await signChecked(signer, payload)
    return Hex.encode(
        requestSigBytes(
            method: input.method, path: input.path, bodyHash: bodyHash, issuedAt: input.issuedAt,
            expiresAt: input.expiresAt, signature: signature))
}

// MARK: - CallerProof

/// The three links of a `CallerProof`, each already hex-encoded by the
/// function that signed it.
public struct CallerProofInput: Sendable, Equatable {
    /// ``DeviceCertificates/certify(rootSeed:device:signPublicKey:kemPublicKey:deviceEpoch:)``
    /// or the wallet's credential: the root's certificate over the device key.
    public var credential: String
    /// ``LoginStatement`` wire bytes, when a session key signs the request.
    /// `nil` on the two-link chain — not the same as `""`: borsh writes
    /// `Option` as a tag byte, so the two produce different bytes.
    public var session: String?
    /// ``signRequest(_:)``.
    public var request: String

    public init(credential: String, session: String? = nil, request: String) {
        self.credential = credential
        self.session = session
        self.request = request
    }
}

/// Concatenate the three links into the `X-Calimero-Proof` value, hex.
///
/// Rust's `CallerProof` is a plain struct of those three fields and borsh
/// writes a struct as its fields back to back, so this is concatenation —
/// with `Option`'s tag byte (`0`, or `1` + the statement) for the session.
public func callerProof(_ input: CallerProofInput) throws -> String {
    var out = try Hex.decodeUnsized(input.credential, label: "credential")
    if let session = input.session {
        out.append(1)
        out.append(try Hex.decodeUnsized(session, label: "session statement"))
    } else {
        out.append(0)
    }
    out.append(try Hex.decodeUnsized(input.request, label: "request signature"))
    return Hex.encode(out)
}

// MARK: - Proof signer

/// What the transport knows about the call it is about to make.
public struct ProofRequest: Sendable, Equatable {
    /// `GET`, `POST`, … exactly as it will be sent.
    public var method: String
    /// The path and query the node will see, as ``signedPath(_:)`` reads them.
    public var path: String
    /// The exact bytes that will be sent; empty for none.
    public var body: Data

    public init(method: String, path: String, body: Data = Data()) {
        self.method = method
        self.path = path
        self.body = body
    }
}

/// Produces the `X-Calimero-Proof` value for one request, or `nil` to send
/// none (a client that only sometimes holds a key stays usable).
public typealias ProofCallback = @Sendable (ProofRequest) async throws -> String?

/// Keys for ``createProofSigner(_:)``.
public struct ProofSignerOptions: Sendable {
    /// The device certificate, hex.
    public var credential: String
    /// ``LoginStatement`` wire bytes, hex — the three-link chain. `nil` for
    /// the two-link chain, where `signerSecret` is the device key itself.
    public var session: String?
    /// The Ed25519 secret that signs each request, hex: the session key when
    /// `session` is set, otherwise the device key. Or pass ``signer``.
    public var signerSecret: String?
    public var signer: (any Signer)?
    /// How long each signature stays valid, seconds. Default 120: this is what
    /// bounds replay, and nothing else does. At most
    /// ``maxRequestProofTTLSeconds``; ``createProofSigner(_:)`` refuses more.
    public var ttlSeconds: UInt64
    /// Unix seconds. Injectable so a test does not depend on the wall clock.
    public var now: @Sendable () -> UInt64

    public init(
        credential: String, session: String? = nil, signerSecret: String? = nil, signer: (any Signer)? = nil,
        ttlSeconds: UInt64 = 120, now: @escaping @Sendable () -> UInt64 = unixSeconds
    ) {
        self.credential = credential
        self.session = session
        self.signerSecret = signerSecret
        self.signer = signer
        self.ttlSeconds = ttlSeconds
        self.now = now
    }
}

/// The longest window a request signature may carry, seconds: core's
/// `MAX_REQUEST_LIFETIME_SECS` (`crates/account/src/caller.rs`). A node refuses
/// a longer one before checking any signature, so asking for it is refused
/// here, before a proof that could only fail is ever minted.
///
/// The window is also the whole of what bounds replay: a two-link proof names
/// no node, so within it the identical request is valid at any node that
/// serves the account. Keep it short.
public let maxRequestProofTTLSeconds: UInt64 = 300

/// `seconds`, when it is a window a node accepts (1 through
/// ``maxRequestProofTTLSeconds``); otherwise an `invalidInput` naming `label`.
func checkedRequestProofTTL(_ seconds: UInt64, label: String) throws -> UInt64 {
    guard seconds >= 1, seconds <= maxRequestProofTTLSeconds else {
        throw AccountError.invalidInput(
            "\(label) must be between 1 and \(maxRequestProofTTLSeconds) seconds, got \(seconds)")
    }
    return seconds
}

/// The current Unix time, whole seconds.
public func unixSeconds() -> UInt64 {
    UInt64(max(0, Date().timeIntervalSince1970))
}

/// Turn a credential and a key into a per-request ``ProofCallback`` — pass it
/// as ``MeroConfig/requestProof`` (`.custom`) or ``TransportHooks/getProof``.
public func createProofSigner(_ options: ProofSignerOptions) throws -> ProofCallback {
    let ttl = try checkedRequestProofTTL(options.ttlSeconds, label: "ttlSeconds")
    let signer = try resolveSigner(options.signerSecret, options.signer, label: "signerSecret")
    return { request in
        let issuedAt = options.now()
        let sig = try await signRequest(
            RequestSigInput(
                method: request.method, path: request.path, body: request.body, issuedAt: issuedAt,
                expiresAt: issuedAt + ttl, signer: signer))
        return try callerProof(CallerProofInput(credential: options.credential, session: options.session, request: sig))
    }
}
