import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Learn a relay's node signing key from its TEE attestation. Port of mero-js
// `src/relay-attestation/attest-node-key.ts`, and of the quote verifier its
// delegated sessions use (`relayQuoteVerifier` in `account/session.ts`).
//
// A login binds a session to the node key the client names, and that key
// must never be taken from the node being logged in to on its word. A TEE
// quote is different: the node cannot put a key into it that the TEE did not
// bind. With `bindNodeKey`, core commits the node's signing key into the
// quote's report data:
//
//   report_data = nonce (32) ‖ SHA-256("calimero.tee-attest.key-binding.v1" ‖ 0^32 ‖ key)
//
// So the client sends a fresh nonce, reads the report data out of the RAW
// quote bytes — never the server's parsed rendering of them — and accepts the
// key only if both halves match, and only once the quote itself verified.

/// A relay's node key, as its quote binds it. (== mero-js `AttestedNodeKey`.)
public struct AttestedNodeKey: Sendable, Equatable {
    /// The relay's node signing key, 64 hex.
    public let nodeKey: String
    /// True when the quote was a mock — no TEE vouched for anything.
    public let mock: Bool

    public init(nodeKey: String, mock: Bool) {
        self.nodeKey = nodeKey
        self.mock = mock
    }
}

/// What ``attestRelayNodeKey(_:)`` needs. (== mero-js `AttestRelayNodeKeyOptions`.)
public struct AttestRelayNodeKeyOptions: Sendable {
    public var relayURL: String
    /// Accept a mock quote. DEV/TEST ONLY: a mock quote carries no
    /// signature, so it proves nothing about the hardware — only that the
    /// node bound this key into something it produced for this nonce.
    public var allowMock: Bool
    /// Verify a real quote the way a sealed transport does — such as
    /// ``createSignedReleaseVerifier(_:)``: the relay's signed mero-tee
    /// release, Intel's chain, every register of its image. Called with this
    /// request's nonce and the node-key binding as the expected report data,
    /// and with the relay's collateral when it asks for it. Takes precedence
    /// over ``verifyQuote``.
    public var verify: (any TransportQuoteVerifier)?
    /// Verify a real quote's signature chain and measurements; throw to refuse.
    public var verifyQuote: (@Sendable (Data) async throws -> Void)?
    public var session: URLSession
    public var timeout: TimeInterval

    public init(
        relayURL: String, allowMock: Bool = false, verify: (any TransportQuoteVerifier)? = nil,
        verifyQuote: (@Sendable (Data) async throws -> Void)? = nil, session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) {
        self.relayURL = relayURL
        self.allowMock = allowMock
        self.verify = verify
        self.verifyQuote = verifyQuote
        self.session = session
        self.timeout = timeout
    }
}

/// Core's `attest_key_binding(None, key)`: `SHA-256(DOMAIN ‖ 0^32 ‖ key)`.
/// (== mero-js `attestKeyBinding`; the same as ``RelayNodeKey/keyBinding(_:)``.)
public func attestKeyBinding(_ nodeKey: Data) -> Data {
    RelayNodeKey.keyBinding(nodeKey)
}

/// The 64 report-data bytes of a quote, read from the quote itself, and
/// whether it is a mock quote. (== mero-js `reportDataOf`; the same as
/// ``RelayNodeKey/reportData(of:)``.)
public func reportDataOf(_ quote: Data) throws -> (reportData: Data, mock: Bool) {
    let (reportData, mock) = try RelayNodeKey.reportData(of: quote)
    return (reportData: reportData, mock: mock)
}

/// Ask a relay for a quote binding its node key to a fresh nonce, verify the
/// quote, check the binding, and return the key. (== mero-js `attestRelayNodeKey`.)
///
/// A real quote needs ``AttestRelayNodeKeyOptions/verify`` (or `verifyQuote`):
/// without one the binding would be checked against bytes nothing has
/// authenticated, so it is refused. A mock quote is refused unless `allowMock`.
public func attestRelayNodeKey(_ options: AttestRelayNodeKeyOptions) async throws -> AttestedNodeKey {
    let nonce = randomBytes(32)
    var body: [String: JSONValue] = ["nonce": .string(Hex.encode(nonce)), "bindNodeKey": true]
    if options.verify?.includeCollateral == true { body["includeCollateral"] = true }
    let request = AccountHTTP.jsonRequest(
        try AccountHTTP.url(options.relayURL, "/admin-api/tee/attest"), method: "POST", body: .object(body),
        timeout: options.timeout)
    let answer = try await AccountHTTP.send(request, session: options.session)
    let data = answer["data"] ?? answer
    guard let quoteB64 = data["quoteB64"]?.stringValue else {
        throw AccountError.relayKeyUnavailable("the relay returned no quote")
    }
    guard let bound = data["boundPublicKey"]?.stringValue, Hex.is32(bound) else {
        throw AccountError.relayKeyUnavailable("boundPublicKey must be 64 hex characters")
    }
    let nodeKey = try Hex.decode(bound, label: "boundPublicKey", bytes: 32)
    guard let quote = Data(base64Encoded: quoteB64) else {
        throw AccountError.relayKeyUnavailable("the relay's quote is not base64")
    }
    let (reportData, mock) = try RelayNodeKey.reportData(of: quote)
    if mock {
        guard options.allowMock else {
            throw AccountError.relayKeyUnavailable(
                "the relay answered with a MOCK quote, which proves nothing about the hardware")
        }
    } else if let verify = options.verify {
        let collateral = try data["collateral"].flatMap(RelayAttestation.typedCollateral)
        let accepted = try await verify.verify(
            TransportQuoteArgs(
                quoteB64: quoteB64, nonce: Hex.encode(nonce),
                reportDataSuffix: Hex.encode(attestKeyBinding(nodeKey)), collateral: collateral))
        guard accepted else {
            throw AccountError.relayKeyUnavailable(
                "the relay's quote did not verify: not a trusted image, or not bound to this request")
        }
    } else if let verifyQuote = options.verifyQuote {
        try await verifyQuote(quote)
    } else {
        throw AccountError.relayKeyUnavailable(
            "a real TDX quote needs a verify (or verifyQuote) to check its signature and measurements")
    }
    try RelayAttestation.checkBinding(reportData, nonce: nonce, nodeKey: nodeKey)
    return AttestedNodeKey(nodeKey: Hex.encode(nodeKey), mock: mock)
}

extension RelayAttestation {
    /// The collateral a relay sent, typed; `nil` for JSON `null`.
    static func typedCollateral(_ json: JSONValue) throws -> DcapCollateral? {
        if json == .null { return nil }
        return try DcapCollateral(json: json)
    }

    /// Report data is this request's nonce, then the binding of the key the relay named.
    static func checkBinding(_ reportData: Data, nonce: Data, nodeKey: Data) throws {
        guard Data(reportData.prefix(32)) == nonce else {
            throw AccountError.relayKeyUnavailable(
                "the quote does not carry our nonce: it was not made for this request")
        }
        guard Data(reportData.suffix(32)) == attestKeyBinding(nodeKey) else {
            throw AccountError.relayKeyUnavailable("the quote does not bind the key the relay named: refusing it")
        }
    }
}

/// A step on the way to verifying a relay's key failed — the relay, the
/// release mirror — rather than its proof: nothing was decided, and trying
/// again may succeed. (== mero-js `RelayKeyTransportError`.)
public struct RelayKeyTransportError: Error, LocalizedError, Sendable {
    public let step: String
    public let reason: String

    public init(step: String, reason: String) {
        self.step = step
        self.reason = reason
    }

    public var errorDescription: String? { "\(step): \(reason)" }

    /// Run `body`, marking whatever it throws as this step's transport failure.
    static func during<T: Sendable>(_ step: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as RelayKeyTransportError {
            throw error
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw RelayKeyTransportError(step: step, reason: reason)
        }
    }
}

/// Verifies a relay's node key by its TEE quote: Intel's DCAP chain, the
/// signed mero-tee release the relay runs, every register of its image, and
/// the binding of the key to this request. The verifier mobile relays are
/// trusted by, in place of the TLS-only ``TLSRelayKeyVerifier``.
/// (== mero-js `relayQuoteVerifier` + `attestRelayNodeKey`.)
///
/// A loopback relay is a dev rig answering mock quotes: its mock is accepted
/// (unless `allowMock` says otherwise). From any other host a mock is refused.
public struct DcapRelayKeyVerifier: RelayKeyVerifier {
    /// The image profile a relay must run. (mero-js `TRUSTED_RELAY_PROFILE`.)
    public static let trustedRelayProfile = TeeTrust.productionProfile
    /// The oldest relay release trusted: the first that serves delegated
    /// context creation and governance at the namespace-op schema this
    /// client signs. (mero-js `MIN_RELAY_RELEASE`.)
    public static let minRelayRelease = "2.3.99"

    /// The quote verifier for a relay, by its URL.
    public let verifierFor: @Sendable (_ relayURL: String) -> any TransportQuoteVerifier
    /// `nil` accepts mock quotes only from loopback relays.
    public let allowMock: Bool?

    /// Verify with `verifierFor(relayURL)`.
    public init(allowMock: Bool? = nil, verifierFor: @escaping @Sendable (String) -> any TransportQuoteVerifier) {
        self.allowMock = allowMock
        self.verifierFor = verifierFor
    }

    /// Verify with `verifier`, whatever the relay.
    public init(verifier: any TransportQuoteVerifier, allowMock: Bool? = nil) {
        self.init(allowMock: allowMock, verifierFor: { _ in verifier })
    }

    /// The signed-release verifier: the relay names its release in
    /// `/admin-api/tee/info`, the release comes from `mirror` (fetched only;
    /// its signature is checked), and the quote must be of that release's
    /// `profile` image, no older than `minReleaseVersion`.
    public init(
        session: URLSession = .shared, mirror: String = TeeTrust.defaultReleaseMirror,
        profile: String = DcapRelayKeyVerifier.trustedRelayProfile,
        minReleaseVersion: String = DcapRelayKeyVerifier.minRelayRelease, allowMock: Bool? = nil,
        dcapVerify: @escaping DcapVerify = { try Dcap.verify($0, collateral: $1, nowSecs: $2) },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.init(
            allowMock: allowMock,
            verifierFor: { relayURL in
                DcapRelayKeyVerifier.signedReleaseVerifier(
                    relayURL: relayURL, session: session, mirror: mirror, profile: profile,
                    minReleaseVersion: minReleaseVersion, dcapVerify: dcapVerify, now: now)
            })
    }

    /// The quote verifier mero-js's delegated sessions trust a hosted relay
    /// with (`relayQuoteVerifier`): the release the relay names in its
    /// `/admin-api/tee/info`, fetched from `mirror` and verified as signed, at
    /// or above `minReleaseVersion`, and its `profile` image. A failure to
    /// reach the relay or the mirror is a ``RelayKeyTransportError``.
    public static func signedReleaseVerifier(
        relayURL: String, session: URLSession = .shared, mirror: String = TeeTrust.defaultReleaseMirror,
        profile: String = DcapRelayKeyVerifier.trustedRelayProfile,
        minReleaseVersion: String = DcapRelayKeyVerifier.minRelayRelease,
        dcapVerify: @escaping DcapVerify = { try Dcap.verify($0, collateral: $1, nowSecs: $2) },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) -> SignedReleaseVerifier {
        let release: @Sendable () async throws -> SignedNodeRelease = {
            try await RelayKeyTransportError.during("fetching the release the relay runs") {
                let version = try await fetchNodeReleaseVersion(relayURL, session: session)
                let url = try cloudNodeReleaseUrl(mirror, version: version)
                return try await fetchNodeRelease(url, session: session)
            }
        }
        return SignedReleaseVerifier(
            options: SignedReleaseVerifierOptions(
                release: release, profile: profile, minReleaseVersion: minReleaseVersion, dcapVerify: dcapVerify,
                now: now))
    }

    public func verify(_ attestation: RelayAttestation) async throws -> String {
        guard let quote = Data(base64Encoded: attestation.quoteB64) else {
            throw AccountError.relayKeyUnavailable("the relay's quote is not base64")
        }
        let nodeKey = try Hex.decode(attestation.boundPublicKey, label: "boundPublicKey", bytes: 32)
        let nonce = try Hex.decode(attestation.nonce, label: "nonce", bytes: 32)
        let (reportData, mock) = try RelayNodeKey.reportData(of: quote)
        if mock {
            guard allowMock ?? RelayNodeKey.isLoopback(attestation.relayURL) else {
                throw AccountError.relayKeyUnavailable(
                    "the relay answered with a MOCK quote, which proves nothing about the hardware")
            }
        } else {
            let collateral = try attestation.collateral.flatMap(RelayAttestation.typedCollateral)
            let accepted = try await verifierFor(attestation.relayURL).verify(
                TransportQuoteArgs(
                    quoteB64: attestation.quoteB64, nonce: attestation.nonce,
                    reportDataSuffix: Hex.encode(attestKeyBinding(nodeKey)), collateral: collateral))
            guard accepted else {
                throw AccountError.relayKeyUnavailable(
                    "the relay's quote did not verify: not a trusted image, or not bound to this request")
            }
        }
        try RelayAttestation.checkBinding(reportData, nonce: nonce, nodeKey: nodeKey)
        return Hex.encode(nodeKey)
    }
}
