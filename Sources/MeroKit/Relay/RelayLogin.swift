import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The client surface a login statement binds a session to.
public enum LoginAudience: Sendable, Equatable {
    /// A browser origin, exactly as the browser spells it.
    case webOrigin(String)
    /// A signed native client, named by its code-signing identity (on iOS, the
    /// bundle identifier).
    case codeSigningId(String)
    /// A command-line client. Binds nothing, deliberately.
    case cli

    var tag: UInt8 {
        switch self {
        case .webOrigin: return 0
        case .codeSigningId: return 1
        case .cli: return 2
        }
    }

    var body: Data {
        switch self {
        case .webOrigin(let origin): return Data(origin.utf8)
        case .codeSigningId(let id): return Data(id.utf8)
        case .cli: return Data()
        }
    }

    /// The audience for this app: its bundle identifier, or `.cli` when it has none.
    public static var current: LoginAudience {
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty { return .codeSigningId(bundleId) }
        return .cli
    }
}

/// The login statement: what a device signs to open an `account_proof` session
/// at a node. Port of mero-js `src/login/login.ts`; core
/// `crates/account/src/tests/login_wire_fixture.rs` pins the vectors.
public enum LoginStatement {
    static let domain = "calimero.auth.login.v1"

    /// The 32-byte preimage the device signs.
    public static func preimage(
        node: String, audience: LoginAudience, challenge: String, sessionKey: String, deviceKey: Data,
        issuedAt: UInt64, expiresAt: UInt64
    ) throws -> Data {
        domainHash(
            domain,
            [
                try Hex.decode(node, label: "node", bytes: 32),
                Data([audience.tag]) + audience.body,
                try Hex.decode(challenge, label: "challenge", bytes: 32),
                try Hex.decode(sessionKey, label: "sessionKey", bytes: 32),
                deviceKey,
                LittleEndian.u64(issuedAt),
                LittleEndian.u64(expiresAt),
            ])
    }

    /// The wire bytes with `signature` appended, hex.
    public static func wire(
        node: String, audience: LoginAudience, challenge: String, sessionKey: String, deviceKey: Data,
        issuedAt: UInt64, expiresAt: UInt64, signature: Data
    ) throws -> String {
        var w = BorshWriter()
        w.raw(try Hex.decode(node, label: "node", bytes: 32))
        w.u8(audience.tag)
        if case .cli = audience {} else { w.bytes(audience.body) }
        w.raw(try Hex.decode(challenge, label: "challenge", bytes: 32))
        w.raw(try Hex.decode(sessionKey, label: "sessionKey", bytes: 32))
        w.raw(deviceKey)
        w.u64(issuedAt)
        w.u64(expiresAt)
        w.raw(signature)
        return Hex.encode(w.data)
    }

    /// Sign a login statement with the device `keys`. Returns hex.
    public static func sign(
        node: String, audience: LoginAudience, challenge: String, sessionKey: String, issuedAt: UInt64,
        expiresAt: UInt64, keys: DeviceKeys
    ) throws -> String {
        let deviceKey = try Ed25519.publicKey(seed: keys.signSecret)
        let message = try preimage(
            node: node, audience: audience, challenge: challenge, sessionKey: sessionKey, deviceKey: deviceKey,
            issuedAt: issuedAt, expiresAt: expiresAt)
        return try wire(
            node: node, audience: audience, challenge: challenge, sessionKey: sessionKey, deviceKey: deviceKey,
            issuedAt: issuedAt, expiresAt: expiresAt, signature: try keys.sign(message))
    }
}

// MARK: - Relay node key

/// What a relay answered to `POST /admin-api/tee/attest {nonce, bindNodeKey: true, includeCollateral: true}`.
public struct RelayAttestation: Sendable {
    public let relayURL: String
    /// The 32-byte nonce this client sent, hex.
    public let nonce: String
    /// The TDX quote (or a `MOCK_TDX_QUOTE_V1` quote on a dev rig), base64.
    public let quoteB64: String
    /// The node key the relay says the quote binds, hex.
    public let boundPublicKey: String
    /// DCAP collateral, as the relay returned it (opaque here).
    public let collateral: JSONValue?
}

/// Decides whether to trust the node key a relay attested to.
///
/// The login statement names the relay's node key, and that key must not come
/// from the party being logged in to on trust alone. mero-js verifies the TDX
/// DCAP quote against a signed mero-tee release. **That is not ported yet**: the
/// default here, ``TLSRelayKeyVerifier``, checks that the quote is bound to this
/// request and to the key named, and otherwise trusts the TLS connection to the
/// relay URL the Cloud manager returned.
///
/// TODO(follow-up): DCAP quote verification on mobile (Intel PCK chain +
/// mero-tee release measurements), or a signed node key published by the cloud
/// beside `relay_url`. Warranted writes do not depend on this — only Bearer
/// reads and SSE do.
public protocol RelayKeyVerifier: Sendable {
    /// Return the node key (64 hex) to log in with, or throw to refuse.
    func verify(_ attestation: RelayAttestation) async throws -> String
}

/// The v1 mobile verifier: TLS + report-data binding, no quote signature check.
///
/// It still refuses what it can decide locally:
/// - a quote whose report data does not carry this request's nonce, or does not
///   bind the key the relay named (`SHA256("calimero.tee-attest.key-binding.v1" ‖ 0³² ‖ key)`);
/// - a **mock** quote from anything but a loopback relay (unless `allowMock`).
public struct TLSRelayKeyVerifier: RelayKeyVerifier {
    public var allowMock: Bool?

    /// `allowMock: nil` accepts mock quotes only from loopback relays.
    public init(allowMock: Bool? = nil) { self.allowMock = allowMock }

    public func verify(_ attestation: RelayAttestation) async throws -> String {
        guard let quote = Data(base64Encoded: attestation.quoteB64) else {
            throw AccountError.relayKeyUnavailable("the relay's quote is not base64")
        }
        let nodeKey = try Hex.decode(attestation.boundPublicKey, label: "boundPublicKey", bytes: 32)
        let (reportData, mock) = try RelayNodeKey.reportData(of: quote)
        if mock {
            let loopback = RelayNodeKey.isLoopback(attestation.relayURL)
            guard allowMock ?? loopback else {
                throw AccountError.relayKeyUnavailable(
                    "the relay answered with a MOCK quote, which proves nothing about the hardware")
            }
        }
        let nonce = try Hex.decode(attestation.nonce, label: "nonce", bytes: 32)
        guard reportData.prefix(32) == nonce else {
            throw AccountError.relayKeyUnavailable(
                "the quote does not carry our nonce: it was not made for this request")
        }
        guard reportData.suffix(32) == RelayNodeKey.keyBinding(nodeKey) else {
            throw AccountError.relayKeyUnavailable("the quote does not bind the key the relay named")
        }
        return Hex.encode(nodeKey)
    }
}

/// A verifier that returns a key pinned out of band (operator-supplied).
public struct PinnedRelayKeyVerifier: RelayKeyVerifier {
    public let nodeKey: String
    public init(nodeKey: String) { self.nodeKey = nodeKey.lowercased() }
    public func verify(_ attestation: RelayAttestation) async throws -> String { nodeKey }
}

/// Learning a relay's node key from its TEE attestation.
public enum RelayNodeKey {
    static let keyBindingDomain = "calimero.tee-attest.key-binding.v1"
    static let mockQuoteHeader = Data("MOCK_TDX_QUOTE_V1".utf8)
    /// TDX quote v4: 48-byte header, then the TD report; report data at +520.
    static let tdxReportDataOffset = 48 + 520

    /// `SHA256(DOMAIN ‖ 0^32 ‖ nodeKey)` — the second half of report data.
    public static func keyBinding(_ nodeKey: Data) -> Data {
        sha256(Data(keyBindingDomain.utf8) + Data(count: 32) + nodeKey)
    }

    /// The 64 report-data bytes of a quote, and whether it is a mock quote.
    public static func reportData(of quote: Data) throws -> (Data, Bool) {
        let mock = quote.count >= mockQuoteHeader.count && quote.prefix(mockQuoteHeader.count) == mockQuoteHeader
        let at = mock ? mockQuoteHeader.count : tdxReportDataOffset
        guard quote.count >= at + 64 else {
            throw AccountError.relayKeyUnavailable(
                "the quote is too short to carry report data (\(quote.count) bytes)")
        }
        let start = quote.startIndex + at
        return (Data(quote[start..<start + 64]), mock)
    }

    static func isLoopback(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Ask the relay to attest, and hand the answer to `verifier`.
    public static func attest(
        relayURL: String, verifier: any RelayKeyVerifier = TLSRelayKeyVerifier(), session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) async throws -> String {
        let nonce = Hex.encode(randomBytes(32))
        let request = AccountHTTP.jsonRequest(
            try AccountHTTP.url(relayURL, "/admin-api/tee/attest"), method: "POST",
            body: ["nonce": .string(nonce), "bindNodeKey": true, "includeCollateral": true], timeout: timeout)
        let body = try await AccountHTTP.send(request, session: session)
        let data = body["data"] ?? body
        guard let quote = data["quoteB64"]?.stringValue else {
            throw AccountError.relayKeyUnavailable("the relay returned no quote")
        }
        guard let bound = data["boundPublicKey"]?.stringValue else {
            throw AccountError.relayKeyUnavailable("the relay named no bound key")
        }
        return try await verifier.verify(
            RelayAttestation(
                relayURL: relayURL, nonce: nonce, quoteB64: quote, boundPublicKey: bound,
                collateral: data["collateral"]))
    }
}

// MARK: - Login

/// Logging in at a relay with the device certificate: `GET /auth/challenge`,
/// then `POST /auth/token` with `auth_method: "account_proof"`.
///
/// The result is an ordinary token bundle, so it drops into a ``Mero`` pointed
/// at the relay — its admin reads and SSE then work as on any node.
public enum RelayLogin {
    public static let defaultTTLSeconds: UInt64 = 300

    public static func login(
        relayURL: String, nodeKey: String, credential: String, keys: DeviceKeys,
        audience: LoginAudience = .current, clientName: String? = nil, ttlSeconds: UInt64 = defaultTTLSeconds,
        session: URLSession = .shared, timeout: TimeInterval = 10, now: Date = Date()
    ) async throws -> TokenData {
        let challengeBody = try await AccountHTTP.send(
            AccountHTTP.jsonRequest(
                try AccountHTTP.url(relayURL, "/auth/challenge"), method: "GET", body: nil, timeout: timeout),
            session: session)
        guard
            let challenge = challengeBody["challenge"]?.stringValue ?? challengeBody["data"]?["challenge"]?.stringValue
        else {
            throw AccountError.protocolViolation("the node issued no challenge")
        }

        // An ephemeral session key, minted per session and thrown away with it.
        let sessionKey = Hex.encode(try Ed25519.publicKey(seed: randomBytes(32)))
        let issuedAt = UInt64(now.timeIntervalSince1970)
        let statement = try LoginStatement.sign(
            node: nodeKey, audience: audience, challenge: challenge, sessionKey: sessionKey, issuedAt: issuedAt,
            expiresAt: issuedAt + ttlSeconds, keys: keys)

        var trimmed = relayURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let body: JSONValue = [
            "auth_method": "account_proof",
            "public_key": .string(sessionKey),
            "client_name": .string(clientName ?? trimmed),
            "timestamp": .number(Double(issuedAt)),
            "provider_data": [
                "challenge": .string(challenge),
                "login_statement": .string(statement),
                "account_proof": .string(credential),
            ],
        ]
        let tokenBody = try await AccountHTTP.send(
            AccountHTTP.jsonRequest(
                try AccountHTTP.url(relayURL, "/auth/token"), method: "POST", body: body, timeout: timeout),
            session: session)
        let access = tokenBody["access_token"]?.stringValue ?? tokenBody["data"]?["access_token"]?.stringValue
        let refresh = tokenBody["refresh_token"]?.stringValue ?? tokenBody["data"]?["refresh_token"]?.stringValue
        guard let access, !access.isEmpty else {
            throw AccountError.protocolViolation("the node minted no session")
        }
        return TokenData(
            accessToken: access, refreshToken: refresh ?? "",
            expiresAt: expiresAtFromJWT(access, fallback: now.addingTimeInterval(3600)))
    }

    /// `POST /auth/logout {refresh_token}` — retires the refresh token. Best effort.
    public static func logout(
        relayURL: String, refreshToken: String, session: URLSession = .shared, timeout: TimeInterval = 10
    ) async {
        guard !refreshToken.isEmpty, let url = try? AccountHTTP.url(relayURL, "/auth/logout") else { return }
        let request = AccountHTTP.jsonRequest(
            url, method: "POST", body: ["refresh_token": .string(refreshToken)], timeout: timeout)
        _ = try? await AccountHTTP.sendRaw(request, session: session)
    }
}
