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
    public static let audience = "mdma:enable-ha-namespace-as-account"
    public static let defaultTTLMs: Int64 = 60_000
    public static let maxTTLMs: Int64 = 5 * 60_000
    static let maxRelayURL = 1024

    /// The claim's JSON, in `JSON.stringify`'s field order (the cloud verifies
    /// the bytes, so the order is the one mero-js writes).
    static func payload(
        namespaceId: String, accountId: String, salt: String, nonce: String, issuedAtMs: Int64, ttlMs: Int64,
        relayURL: String?
    ) -> String {
        var fields = [
            "\"v\":1",
            "\"audience\":\(CanonicalJSON.quote(audience))",
            "\"group_id\":\(CanonicalJSON.quote(namespaceId))",
            "\"account_id\":\(CanonicalJSON.quote(accountId))",
            "\"salt\":\(CanonicalJSON.quote(salt))",
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
