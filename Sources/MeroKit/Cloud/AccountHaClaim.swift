import Foundation

/// The `ownership_proof` an account presents to enable HA for a namespace it
/// founded through a relay (`POST /api/cloud/accounts/{a}/namespaces/{ns}/enable-ha`).
public struct AccountOwnershipProof: Sendable, Equatable {
    public let kind: String
    /// The account's `AccountProof<DeviceCert>`, hex.
    public let credential: String
    /// base64 of the UTF-8 JSON claim.
    public let signedPayload: String
    /// base64 Ed25519 by the certified device key.
    public let signature: String

    var json: JSONValue {
        [
            "kind": .string(kind), "credential": .string(credential), "signed_payload": .string(signedPayload),
            "signature": .string(signature),
        ]
    }
}

/// The founder's claim, port of mero-js `src/cloud/account-ownership.ts`
/// (`signAccountHaClaim`).
///
/// A node proves ownership with its group key, which a nodeless account does not
/// hold. The account instead proves it is the FOUNDER: a namespace id is
/// `domain_hash("calimero.namespace.id.v1", [founder, salt])`, so only the
/// founding account with its salt reproduces it. The device key signs
/// `"calimero.mdma.account-ownership-claim.v1\0" ‖ payload`, `payload` being the
/// UTF-8 JSON sent (base64) as `signed_payload`.
public enum AccountHaClaim {
    static let domain = "calimero.mdma.account-ownership-claim.v1\u{0}"
    /// The audience of the anonymous account route (no `subject`).
    /// (== mero-js `ACCOUNT_HA_AUDIENCE`.)
    public static let audience = "mdma:enable-ha-namespace-as-account"
    /// The audience of the session route's claim (`/api/cloud/me/...`), bound
    /// to one login by `subject`. (== mero-js `ACCOUNT_OWNERSHIP_AUDIENCE`.)
    public static let ownershipAudience = "mdma:enable-ha-namespace"
    public static let defaultTTLMs: Int64 = 60_000
    public static let maxTTLMs: Int64 = 5 * 60_000
    static let maxRelayURL = 1024

    /// The claim's JSON, in `JSON.stringify`'s field order (the cloud verifies
    /// the bytes, so the order is the one mero-js writes).
    ///
    /// `subject` is spliced in after `salt` only when given, so the account
    /// claim has no `subject` key at all (the cloud tells the two apart by it).
    static func payload(
        namespaceId: String, accountId: String, salt: String, nonce: String, issuedAtMs: Int64, ttlMs: Int64,
        relayURL: String?, audience claimAudience: String = AccountHaClaim.audience, subject: String? = nil
    ) -> String {
        var fields = [
            "\"v\":1",
            "\"audience\":\(CanonicalJSON.quote(claimAudience))",
            "\"group_id\":\(CanonicalJSON.quote(namespaceId))",
            "\"account_id\":\(CanonicalJSON.quote(accountId))",
            "\"salt\":\(CanonicalJSON.quote(salt))",
        ]
        if let subject { fields.append("\"subject\":\(CanonicalJSON.quote(subject))") }
        fields += [
            "\"nonce\":\(CanonicalJSON.quote(nonce))",
            "\"issued_at_ms\":\(issuedAtMs)",
            "\"expires_at_ms\":\(issuedAtMs + ttlMs)",
        ]
        if let relayURL { fields.append("\"relay_url\":\(CanonicalJSON.quote(relayURL))") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Sign the founder's claim for the anonymous account route.
    public static func sign(
        namespaceId: String, accountId: String, salt: String, credential: String, keys: DeviceKeys,
        relayURL: String? = nil, ttlMs: Int64 = defaultTTLMs, nowMs: Int64? = nil, nonce: String? = nil
    ) throws -> AccountOwnershipProof {
        if let relayURL, relayURL.isEmpty || relayURL.count > maxRelayURL {
            throw AccountError.invalidInput("relayUrl must be a non-empty string of at most \(maxRelayURL) characters")
        }
        guard ttlMs > 0, ttlMs <= maxTTLMs else { throw AccountError.invalidInput("ttlMs must be in (0, \(maxTTLMs)]") }
        func hex32(_ value: String, _ what: String) throws -> String {
            Hex.encode(try Hex.decode(value, label: what, bytes: 32))
        }
        let issued = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let text = payload(
            namespaceId: try hex32(namespaceId, "namespaceId"), accountId: try hex32(accountId, "accountId"),
            salt: try hex32(salt, "salt"), nonce: nonce ?? Hex.encode(randomBytes(16)), issuedAtMs: issued,
            ttlMs: ttlMs, relayURL: relayURL)
        let bytes = Data(text.utf8)
        let signature = try keys.sign(Data(domain.utf8) + bytes)
        return AccountOwnershipProof(
            kind: "account", credential: credential, signedPayload: bytes.base64EncodedString(),
            signature: signature.base64EncodedString())
    }
}

/// What ``signAccountOwnershipClaim(_:)`` needs. (== mero-js `AccountOwnershipClaimInput`.)
public struct AccountOwnershipClaimInput: Sendable {
    /// The namespace, hex: the id founding returned.
    public var namespaceId: String
    /// The founding account, hex.
    public var accountId: String
    /// The salt founding returned, hex (32 bytes).
    public var salt: String
    /// The account's `AccountProof<DeviceCert>`, hex.
    public var credential: String
    /// The cloud login's email: the claim is for this login only.
    public var subject: String
    /// The certified device's secret, hex. Give this or ``signer``.
    public var deviceSecret: String?
    public var signer: (any Signer)?
    /// Lifetime; default one minute, at most five.
    public var ttlMs: Int64
    /// The clock, epoch ms (tests).
    public var nowMs: Int64?

    public init(
        namespaceId: String, accountId: String, salt: String, credential: String, subject: String,
        deviceSecret: String? = nil, signer: (any Signer)? = nil, ttlMs: Int64 = AccountHaClaim.defaultTTLMs,
        nowMs: Int64? = nil
    ) {
        self.namespaceId = namespaceId
        self.accountId = accountId
        self.salt = salt
        self.credential = credential
        self.subject = subject
        self.deviceSecret = deviceSecret
        self.signer = signer
        self.ttlMs = ttlMs
        self.nowMs = nowMs
    }
}

/// What ``signAccountHaClaim(_:)`` needs: the session claim minus `subject`,
/// plus the founding relay. (== mero-js `AccountHaClaimInput`.)
public struct AccountHaClaimInput: Sendable {
    public var namespaceId: String
    public var accountId: String
    public var salt: String
    public var credential: String
    public var deviceSecret: String?
    public var signer: (any Signer)?
    /// The relay that founded the namespace; signed in so nobody can swap it.
    public var relayURL: String?
    public var ttlMs: Int64
    public var nowMs: Int64?

    public init(
        namespaceId: String, accountId: String, salt: String, credential: String, deviceSecret: String? = nil,
        signer: (any Signer)? = nil, relayURL: String? = nil, ttlMs: Int64 = AccountHaClaim.defaultTTLMs,
        nowMs: Int64? = nil
    ) {
        self.namespaceId = namespaceId
        self.accountId = accountId
        self.salt = salt
        self.credential = credential
        self.deviceSecret = deviceSecret
        self.signer = signer
        self.relayURL = relayURL
        self.ttlMs = ttlMs
        self.nowMs = nowMs
    }
}

/// The founder's claim for the **session** route
/// (``CloudClient/enableFoundedNamespaceHa(_:ownershipProof:)``), bound to one
/// cloud login by `subject` under ``AccountHaClaim/ownershipAudience``.
/// (== mero-js `signAccountOwnershipClaim`.)
public func signAccountOwnershipClaim(_ input: AccountOwnershipClaimInput) async throws -> AccountOwnershipProof {
    guard !input.subject.isEmpty else { throw AccountError.invalidInput("subject must be the cloud login email") }
    return try await AccountHaClaim.signClaim(
        AccountHaClaim.ClaimFields(
            namespaceId: input.namespaceId, accountId: input.accountId, salt: input.salt,
            credential: input.credential, ttlMs: input.ttlMs, nowMs: input.nowMs),
        signer: try resolveSigner(input.deviceSecret, input.signer, label: "deviceSecret"),
        audience: AccountHaClaim.ownershipAudience, subject: input.subject, relayURL: nil)
}

/// The founder's claim for the **anonymous** account route, from a device
/// secret or a ``Signer``. `AccountHaClaim.sign` is the same claim from
/// ``DeviceKeys``. (== mero-js `signAccountHaClaim`.)
public func signAccountHaClaim(_ input: AccountHaClaimInput) async throws -> AccountOwnershipProof {
    try await AccountHaClaim.signClaim(
        AccountHaClaim.ClaimFields(
            namespaceId: input.namespaceId, accountId: input.accountId, salt: input.salt,
            credential: input.credential, ttlMs: input.ttlMs, nowMs: input.nowMs),
        signer: try resolveSigner(input.deviceSecret, input.signer, label: "deviceSecret"),
        audience: AccountHaClaim.audience, subject: nil, relayURL: input.relayURL)
}

extension AccountHaClaim {
    /// What every claim carries, whatever its route.
    struct ClaimFields: Sendable {
        let namespaceId: String
        let accountId: String
        let salt: String
        let credential: String
        let ttlMs: Int64
        let nowMs: Int64?
        var nonce: String?
    }

    /// Validate, build and sign one claim through `signer`.
    static func signClaim(
        _ fields: ClaimFields, signer: any Signer, audience claimAudience: String, subject: String?,
        relayURL: String?
    ) async throws -> AccountOwnershipProof {
        if let relayURL, relayURL.isEmpty || relayURL.count > maxRelayURL {
            throw AccountError.invalidInput("relayUrl must be a non-empty string of at most \(maxRelayURL) characters")
        }
        guard fields.ttlMs > 0, fields.ttlMs <= maxTTLMs else {
            throw AccountError.invalidInput("ttlMs must be in (0, \(maxTTLMs)]")
        }
        func hex32(_ value: String, _ what: String) throws -> String {
            Hex.encode(try Hex.decode(value, label: what, bytes: 32))
        }
        let issued = fields.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let text = payload(
            namespaceId: try hex32(fields.namespaceId, "namespaceId"),
            accountId: try hex32(fields.accountId, "accountId"), salt: try hex32(fields.salt, "salt"),
            nonce: fields.nonce ?? Hex.encode(randomBytes(16)), issuedAtMs: issued, ttlMs: fields.ttlMs,
            relayURL: relayURL, audience: claimAudience, subject: subject)
        let bytes = Data(text.utf8)
        let signature = try await signChecked(signer, Data(domain.utf8) + bytes)
        return AccountOwnershipProof(
            kind: "account", credential: fields.credential, signedPayload: bytes.base64EncodedString(),
            signature: signature.base64EncodedString())
    }
}
