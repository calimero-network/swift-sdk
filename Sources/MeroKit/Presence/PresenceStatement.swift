import Foundation

/// The bytes a device signs for one presence update: the borsh of core's
/// `PresenceStatement` (`calimero_node_primitives::presence`). Port of mero-js
/// `presence/statement.ts`, pinned to core's vector in the tests so the two
/// encoders cannot drift.
public enum PresenceStatement {
    /// core's `PRESENCE_DOMAIN`: part of the signed bytes.
    public static let domain = Data("calimero/presence/1".utf8)

    /// `sha256(borsh(Option<Vec<u8>>))`: `None` is `[0]`, `Some(v)` is
    /// `[1] ‖ u32le(len) ‖ v`. A retract (`nil`) hashes differently from an
    /// empty state.
    public static func stateHash(_ state: Data?) -> Data {
        var writer = BorshWriter()
        writer.optionBytes(state)
        return sha256(writer.data)
    }

    /// What the device key signs, raw:
    /// `domain ‖ context ‖ author ‖ u64le(seq) ‖ u64le(sentAtMs) ‖ stateHash`.
    ///
    /// `contextId` and `author` (the device's signing key) are 64 hex each.
    public static func bytes(
        contextId: String, author: String, seq: UInt64, sentAtMs: UInt64, state: Data?
    ) throws -> Data {
        var writer = BorshWriter()
        writer.raw(domain)
        writer.raw(try Hex.decode(contextId, label: "contextId", bytes: 32))
        writer.raw(try Hex.decode(author, label: "author", bytes: 32))
        writer.u64(seq)
        writer.u64(sentAtMs)
        writer.raw(stateHash(state))
        return writer.data
    }

    /// A ready-to-send `presence-intents` body: the statement signed with the
    /// device key in `keys`, so a caller never assembles the signature itself.
    ///
    /// `state` travels as hex, or `nil` to retract; `authorProof` is the
    /// device certificate (`AccountProof<DeviceCert>`, hex) that ties the key
    /// to its account.
    public static func signedIntent(
        contextId: String, state: Data?, seq: UInt64, sentAtMs: UInt64, keys: DeviceKeys, authorProof: String
    ) throws -> PresenceIntentRequest {
        let statement = try bytes(
            contextId: contextId, author: keys.signPublicKey, seq: seq, sentAtMs: sentAtMs, state: state)
        let signature = try keys.sign(statement)
        return PresenceIntentRequest(
            state: state.map { Hex.encode($0) }, seq: seq, sentAtMs: sentAtMs, signature: Hex.encode(signature),
            authorProof: authorProof)
    }
}
